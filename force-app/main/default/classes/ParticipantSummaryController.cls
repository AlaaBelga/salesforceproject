/**
 * Read-only data for the Participant Summary component.
 *
 * What it answers (from the kickoff notes):
 *   Omar:   Am I signed up? When is my next class? Can my family still come Saturday?
 *   Carlos: Who is this? Did they come last time? How many sessions toward the certificate?
 *
 * Privacy: the tablet is readable by everyone in line, so this class never reads or returns
 * birthdate, phone, email, gender identity or any free-text notes. Only the fields listed
 * in the queries below ever leave the server.
 *
 * Read only: no DML anywhere in this class.
 *
 * Data model it expects (see README):
 *   - Person       = Person Account
 *   - Household    = Business Account + Party Relationship Group (Type = Household),
 *                    linked to each member's Contact by an Account Contact Relationship
 *   - Enrollment   = Program Enrollment (pantry on the household account, class on the person)
 *   - Class signup = Benefit Disbursement with a Benefit Session
 *   - Pantry visit = Benefit Disbursement with no session, Status = Completed
 */
public with sharing class ParticipantSummaryController {

    // ---- Settings: change them here and nowhere else ----
    @TestVisible private static final String PANTRY_KEYWORD = 'pantry';
    @TestVisible private static final String CLASS_KEYWORD = 'class';
    @TestVisible private static final Integer CERTIFICATE_SESSIONS_REQUIRED = 10;
    @TestVisible private static final Integer COURSE_SESSIONS_TOTAL = 12;
    @TestVisible private static final Integer REGULARITY_WEEKS = 8;
    @TestVisible private static final Integer LAPSED_AFTER_DAYS = 28;
    @TestVisible private static final Integer RECENT_SESSIONS_SHOWN = 5;
    @TestVisible private static final Integer UPCOMING_SESSIONS_SHOWN = 3;

    private static final String DISBURSEMENT_ATTENDED = 'Completed';
    private static final String DISBURSEMENT_SIGNED_UP = 'Enrolled';
    private static final String SESSION_CANCELLED = 'Cancelled';

    // ---- What the component receives ----

    public class Summary {
        @AuraEnabled public Boolean isPersonRecord;
        @AuraEnabled public String personName;
        @AuraEnabled public Boolean nothingOnFile;
        @AuraEnabled public Integer householdCount;
        @AuraEnabled public HouseholdInfo household;
        @AuraEnabled public PantryInfo pantry;
        @AuraEnabled public ClassInfo classes;
    }

    public class HouseholdInfo {
        @AuraEnabled public String name;
        @AuraEnabled public Integer size;
        // 'visit' = reported at the last recorded visit, 'intake' = first-day figure
        @AuraEnabled public String sizeSource;
        @AuraEnabled public Date sizeAsOf;
        @AuraEnabled public Integer bags;
    }

    public class PantryInfo {
        @AuraEnabled public Boolean isEnrolled = false;
        @AuraEnabled public String enrollmentStatus;
        @AuraEnabled public Boolean isActive = false;
        @AuraEnabled public Date startDate;
        @AuraEnabled public Boolean hasVisitRecords = false;
        @AuraEnabled public Date lastVisitDate;
        @AuraEnabled public Integer daysSinceLastVisit;
        @AuraEnabled public Integer visitsInWindow = 0;
        // One flag per week, oldest first, last entry = this week
        @AuraEnabled public List<Boolean> weeks = new List<Boolean>();
        @AuraEnabled public Boolean isLapsed = false;
    }

    public class ClassInfo {
        @AuraEnabled public List<ClassEnrollmentInfo> enrollments = new List<ClassEnrollmentInfo>();
        @AuraEnabled public List<SessionInfo> upcoming = new List<SessionInfo>();
        @AuraEnabled public List<SessionInfo> recent = new List<SessionInfo>();
        @AuraEnabled public SessionInfo lastSession;
    }

    public class ClassEnrollmentInfo {
        @AuraEnabled public Id enrollmentId;
        @AuraEnabled public String programName;
        @AuraEnabled public String status;
        @AuraEnabled public Boolean isActive;
        @AuraEnabled public Date startDate;
        @AuraEnabled public Integer attended;
        @AuraEnabled public Integer required;
        @AuraEnabled public Integer totalSessions;
        @AuraEnabled public Boolean certificateMet;
    }

    public class SessionInfo {
        @AuraEnabled public Id sessionId;
        @AuraEnabled public String sessionName;
        @AuraEnabled public Datetime startDateTime;
        @AuraEnabled public String sessionStatus;
        // Enrolled / Completed / Absent / Excused
        @AuraEnabled public String signUpStatus;
    }

    // ---- Entry point ----

    @AuraEnabled
    public static Summary getSummary(Id recordId) {
        try {
            return buildSummary(recordId);
        } catch (AuraHandledException e) {
            throw e;
        } catch (QueryException e) {
            throw friendly(
                'Some of the data for this summary could not be read. '
                + 'You may be missing access to a field or object. ' + e.getMessage()
            );
        } catch (Exception e) {
            throw friendly('The summary could not be loaded. ' + e.getMessage());
        }
    }

    private static Summary buildSummary(Id recordId) {
        Summary result = new Summary();

        List<Account> accounts = [
            SELECT Id, Name, IsPersonAccount, PersonContactId
            FROM Account
            WHERE Id = :recordId
            WITH USER_MODE
            LIMIT 1
        ];
        if (accounts.isEmpty()) {
            throw friendly('This record could not be found, or you do not have access to it.');
        }
        Account acc = accounts[0];
        Boolean isPerson = acc.IsPersonAccount;
        Id personContactId = isPerson ? acc.PersonContactId : null;
        result.isPersonRecord = isPerson;
        result.personName = isPerson ? acc.Name : null;

        // ---- Household: person's contact -> relationship -> household account -> group ----
        Set<Id> householdAccountIds = new Set<Id>();
        if (isPerson) {
            if (personContactId != null) {
                for (AccountContactRelation rel : [
                    SELECT AccountId
                    FROM AccountContactRelation
                    WHERE ContactId = :personContactId AND AccountId != :recordId AND IsActive = true
                    WITH USER_MODE
                ]) {
                    householdAccountIds.add(rel.AccountId);
                }
            }
        } else {
            // Opened on a household account instead of a person
            householdAccountIds.add(recordId);
        }

        PartyRelationshipGroup household = null;
        Integer householdCount = 0;
        if (!householdAccountIds.isEmpty()) {
            List<PartyRelationshipGroup> groups = [
                SELECT Id, Name, AccountId, GroupSize
                FROM PartyRelationshipGroup
                WHERE AccountId IN :householdAccountIds AND Type = 'Household' AND Status = 'Active'
                WITH USER_MODE
                ORDER BY Name
            ];
            householdCount = groups.size();
            if (!groups.isEmpty()) {
                household = groups[0];
            }
        }
        result.householdCount = householdCount;

        // ---- Enrollments: the person's own, plus the household's ----
        Set<Id> accountIds = new Set<Id>{ recordId };
        if (household != null) {
            accountIds.add(household.AccountId);
        }
        Set<Id> contactIds = new Set<Id>();
        if (personContactId != null) {
            contactIds.add(personContactId);
        }

        List<ProgramEnrollment> enrollments = [
            SELECT Id, AccountId, ContactId, Program.Name, Status, IsActive, StartDate
            FROM ProgramEnrollment
            WHERE AccountId IN :accountIds OR ContactId IN :contactIds
            WITH USER_MODE
            ORDER BY StartDate DESC NULLS LAST
        ];

        ProgramEnrollment pantryEnrollment = null;
        List<ProgramEnrollment> classEnrollments = new List<ProgramEnrollment>();
        Set<Id> enrollmentIds = new Set<Id>();
        for (ProgramEnrollment pe : enrollments) {
            enrollmentIds.add(pe.Id);
            String programName = pe.Program != null ? pe.Program.Name : null;
            if (hasKeyword(programName, PANTRY_KEYWORD)) {
                if (pantryEnrollment == null || (pe.IsActive && !pantryEnrollment.IsActive)) {
                    pantryEnrollment = pe;
                }
            } else if (hasKeyword(programName, CLASS_KEYWORD)) {
                classEnrollments.add(pe);
            }
        }

        // ---- Visits and class sign-ups (both are Benefit Disbursements) ----
        Set<Id> recipientIds = new Set<Id>(accountIds);
        recipientIds.addAll(contactIds);
        List<BenefitDisbursement> disbursements = [
            SELECT Id, ProgramEnrollmentId, RecipientId, BenefitSessionId,
                   DisbursementStatus, ActualCompletionDate, RecipientCount
            FROM BenefitDisbursement
            WHERE ProgramEnrollmentId IN :enrollmentIds OR RecipientId IN :recipientIds
            WITH USER_MODE
            ORDER BY ActualCompletionDate DESC
            LIMIT 1000
        ];

        Id householdAccountId = household != null ? household.AccountId : null;
        List<Date> visitDates = new List<Date>();
        Date lastVisit = null;
        Integer lastVisitSize = null;
        Map<Id, BenefitDisbursement> signUpBySession = new Map<Id, BenefitDisbursement>();
        Map<Id, Integer> attendedByEnrollment = new Map<Id, Integer>();

        for (BenefitDisbursement d : disbursements) {
            if (d.BenefitSessionId != null) {
                signUpBySession.put(d.BenefitSessionId, d);
                if (d.DisbursementStatus == DISBURSEMENT_ATTENDED && d.ProgramEnrollmentId != null) {
                    Integer soFar = attendedByEnrollment.get(d.ProgramEnrollmentId);
                    attendedByEnrollment.put(d.ProgramEnrollmentId, (soFar == null ? 0 : soFar) + 1);
                }
            } else if (d.DisbursementStatus == DISBURSEMENT_ATTENDED && d.ActualCompletionDate != null) {
                Boolean isPantryVisit =
                    (pantryEnrollment != null && d.ProgramEnrollmentId == pantryEnrollment.Id)
                    || (householdAccountId != null && d.RecipientId == householdAccountId);
                if (isPantryVisit) {
                    Date visitDate = d.ActualCompletionDate.date();
                    visitDates.add(visitDate);
                    if (lastVisit == null || visitDate > lastVisit) {
                        lastVisit = visitDate;
                        lastVisitSize = d.RecipientCount;
                    }
                }
            }
        }

        // ---- Sessions for the class sign-ups ----
        List<BenefitSession> sessions = new List<BenefitSession>();
        if (!signUpBySession.isEmpty()) {
            Set<Id> sessionIds = signUpBySession.keySet();
            sessions = [
                SELECT Id, Name, StartDateTime, Status
                FROM BenefitSession
                WHERE Id IN :sessionIds
                WITH USER_MODE
                ORDER BY StartDateTime ASC
            ];
        }
        Datetime rightNow = Datetime.now();
        List<SessionInfo> upcoming = new List<SessionInfo>();
        List<SessionInfo> past = new List<SessionInfo>();
        for (BenefitSession s : sessions) {
            if (s.Status == SESSION_CANCELLED) {
                continue;
            }
            BenefitDisbursement signUp = signUpBySession.get(s.Id);
            SessionInfo info = new SessionInfo();
            info.sessionId = s.Id;
            info.sessionName = s.Name;
            info.startDateTime = s.StartDateTime;
            info.sessionStatus = s.Status;
            info.signUpStatus = signUp.DisbursementStatus;
            if (s.StartDateTime != null && s.StartDateTime >= rightNow) {
                if (signUp.DisbursementStatus == DISBURSEMENT_SIGNED_UP
                    && upcoming.size() < UPCOMING_SESSIONS_SHOWN) {
                    upcoming.add(info);
                }
            } else {
                past.add(info);
            }
        }
        List<SessionInfo> recent = new List<SessionInfo>();
        for (Integer i = past.size() - 1; i >= 0 && recent.size() < RECENT_SESSIONS_SHOWN; i--) {
            recent.add(past[i]);
        }

        // ---- Assemble ----
        PantryInfo pantry = new PantryInfo();
        if (pantryEnrollment != null) {
            pantry.isEnrolled = true;
            pantry.enrollmentStatus = pantryEnrollment.Status;
            pantry.isActive = pantryEnrollment.IsActive;
            pantry.startDate = pantryEnrollment.StartDate;
        }
        Date today = Date.today();
        pantry.hasVisitRecords = !visitDates.isEmpty();
        if (lastVisit != null) {
            pantry.lastVisitDate = lastVisit;
            pantry.daysSinceLastVisit = lastVisit.daysBetween(today);
        }
        pantry.weeks = weekFlags(visitDates, today, REGULARITY_WEEKS);
        pantry.visitsInWindow = countInWindow(visitDates, today, REGULARITY_WEEKS * 7);
        pantry.isLapsed = isLapsed(pantry.daysSinceLastVisit, LAPSED_AFTER_DAYS);
        result.pantry = pantry;

        ClassInfo classInfo = new ClassInfo();
        for (ProgramEnrollment pe : classEnrollments) {
            ClassEnrollmentInfo ci = new ClassEnrollmentInfo();
            ci.enrollmentId = pe.Id;
            ci.programName = pe.Program != null ? pe.Program.Name : null;
            ci.status = pe.Status;
            ci.isActive = pe.IsActive;
            ci.startDate = pe.StartDate;
            Integer attended = attendedByEnrollment.get(pe.Id);
            ci.attended = attended == null ? 0 : attended;
            ci.required = CERTIFICATE_SESSIONS_REQUIRED;
            ci.totalSessions = COURSE_SESSIONS_TOTAL;
            ci.certificateMet = ci.attended >= CERTIFICATE_SESSIONS_REQUIRED;
            classInfo.enrollments.add(ci);
        }
        classInfo.upcoming = upcoming;
        classInfo.recent = recent;
        classInfo.lastSession = recent.isEmpty() ? null : recent[0];
        result.classes = classInfo;

        if (household != null) {
            HouseholdInfo h = new HouseholdInfo();
            h.name = household.Name;
            if (lastVisitSize != null && lastVisitSize > 0) {
                h.size = lastVisitSize;
                h.sizeSource = 'visit';
                h.sizeAsOf = lastVisit;
            } else {
                h.size = household.GroupSize;
                h.sizeSource = 'intake';
            }
            h.bags = bagsFor(h.size);
            result.household = h;
        }

        result.nothingOnFile = household == null && enrollments.isEmpty() && disbursements.isEmpty();
        return result;
    }

    // ---- Small rules, kept separate so they can be tested on their own ----

    /** Omar packs one bag up to 3 people, two bags for 4 to 6, three bags above that. */
    @TestVisible
    private static Integer bagsFor(Integer householdSize) {
        if (householdSize == null || householdSize < 1) {
            return null;
        }
        if (householdSize <= 3) {
            return 1;
        }
        if (householdSize <= 6) {
            return 2;
        }
        return 3;
    }

    /** One flag per week, oldest first. The last entry is the current week (0 to 6 days ago). */
    @TestVisible
    private static List<Boolean> weekFlags(List<Date> visitDates, Date today, Integer weeks) {
        List<Boolean> flags = new List<Boolean>();
        for (Integer i = 0; i < weeks; i++) {
            flags.add(false);
        }
        for (Date visitDate : visitDates) {
            Integer daysAgo = visitDate.daysBetween(today);
            if (daysAgo < 0) {
                continue;
            }
            Integer weeksAgo = (daysAgo / 7.0).intValue();
            if (weeksAgo < weeks) {
                flags[weeks - 1 - weeksAgo] = true;
            }
        }
        return flags;
    }

    @TestVisible
    private static Integer countInWindow(List<Date> visitDates, Date today, Integer windowDays) {
        Integer count = 0;
        for (Date visitDate : visitDates) {
            Integer daysAgo = visitDate.daysBetween(today);
            if (daysAgo >= 0 && daysAgo < windowDays) {
                count++;
            }
        }
        return count;
    }

    @TestVisible
    private static Boolean isLapsed(Integer daysSinceLastVisit, Integer afterDays) {
        return daysSinceLastVisit != null && daysSinceLastVisit > afterDays;
    }

    @TestVisible
    private static Boolean hasKeyword(String programName, String keyword) {
        return programName != null && programName.containsIgnoreCase(keyword);
    }

    private static AuraHandledException friendly(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }
}
