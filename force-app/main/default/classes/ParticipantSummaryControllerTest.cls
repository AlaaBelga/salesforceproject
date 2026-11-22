@IsTest
private class ParticipantSummaryControllerTest {

    // ---- Rules that need no data ----

    @IsTest
    static void bagsFollowTheHouseholdSizeRule() {
        System.assertEquals(null, ParticipantSummaryController.bagsFor(null), 'No size, no bags');
        System.assertEquals(null, ParticipantSummaryController.bagsFor(0), 'Zero is not a size');
        System.assertEquals(1, ParticipantSummaryController.bagsFor(1));
        System.assertEquals(1, ParticipantSummaryController.bagsFor(3));
        System.assertEquals(2, ParticipantSummaryController.bagsFor(4));
        System.assertEquals(2, ParticipantSummaryController.bagsFor(6));
        System.assertEquals(3, ParticipantSummaryController.bagsFor(7));
        System.assertEquals(3, ParticipantSummaryController.bagsFor(12));
    }

    @IsTest
    static void weekFlagsMarkTheWeeksThatHadAVisit() {
        Date today = Date.newInstance(2026, 11, 22);
        List<Date> visits = new List<Date>{
            today,                      // this week
            today.addDays(-6),          // still this week
            today.addDays(-7),          // one week ago
            today.addDays(-21),         // three weeks ago
            today.addDays(-200),        // outside the window
            today.addDays(3)            // in the future, ignored
        };
        List<Boolean> flags = ParticipantSummaryController.weekFlags(visits, today, 8);
        System.assertEquals(8, flags.size());
        System.assertEquals(true, flags[7], 'This week');
        System.assertEquals(true, flags[6], 'One week ago');
        System.assertEquals(false, flags[5], 'Two weeks ago');
        System.assertEquals(true, flags[4], 'Three weeks ago');
        System.assertEquals(false, flags[0], 'Eight weeks ago');
    }

    @IsTest
    static void countsOnlyVisitsInsideTheWindow() {
        Date today = Date.newInstance(2026, 11, 22);
        List<Date> visits = new List<Date>{ today, today.addDays(-55), today.addDays(-56), today.addDays(2) };
        System.assertEquals(2, ParticipantSummaryController.countInWindow(visits, today, 56));
    }

    @IsTest
    static void lapsedMeansLongerThanTheLimitSinceTheLastVisit() {
        System.assertEquals(false, ParticipantSummaryController.isLapsed(null, 28), 'No visits is not lapsed');
        System.assertEquals(false, ParticipantSummaryController.isLapsed(28, 28));
        System.assertEquals(true, ParticipantSummaryController.isLapsed(29, 28));
    }

    @IsTest
    static void programsAreMatchedByKeyword() {
        System.assertEquals(true, ParticipantSummaryController.hasKeyword('Saturday Food Pantry', 'pantry'));
        System.assertEquals(false, ParticipantSummaryController.hasKeyword('Saturday Food Pantry', 'class'));
        System.assertEquals(false, ParticipantSummaryController.hasKeyword(null, 'pantry'));
    }

    // ---- With records (needs Person Accounts and Contacts to Multiple Accounts enabled) ----

    @IsTest
    static void aBrandNewPersonShowsAsNothingOnFile() {
        Account person = makePersonAccount('Newcomer');

        ParticipantSummaryController.Summary s = ParticipantSummaryController.getSummary(person.Id);

        System.assertEquals(true, s.isPersonRecord);
        System.assertEquals(true, s.nothingOnFile, 'A new person must get a clear empty state');
        System.assertEquals(null, s.household);
        System.assertEquals(false, s.pantry.isEnrolled);
        System.assertEquals(0, s.classes.enrollments.size());
    }

    @IsTest
    static void aHouseholdMemberSeesTheHouseholdAndItsSize() {
        Account person = makePersonAccount('Member');
        Account householdAccount = makeHouseholdAccount('Test Household (Ash St)');
        insert new PartyRelationshipGroup(
            Name = 'Test Household (Ash St)',
            AccountId = householdAccount.Id,
            Type = 'Household',
            Status = 'Active',
            GroupSize = 5
        );
        insert new AccountContactRelation(
            AccountId = householdAccount.Id,
            ContactId = person.PersonContactId,
            Roles = 'Other'
        );

        ParticipantSummaryController.Summary s = ParticipantSummaryController.getSummary(person.Id);

        System.assertNotEquals(null, s.household, 'Household should be found through the relationship');
        System.assertEquals('Test Household (Ash St)', s.household.name);
        System.assertEquals(5, s.household.size);
        System.assertEquals('intake', s.household.sizeSource, 'No visits yet, so the intake figure is used');
        System.assertEquals(2, s.household.bags);
        System.assertEquals(false, s.nothingOnFile);
    }

    // ---- Helpers ----

    private static Account makePersonAccount(String lastName) {
        Id personRecordTypeId = [
            SELECT Id FROM RecordType WHERE SObjectType = 'Account' AND IsPersonType = true LIMIT 1
        ].Id;
        Account a = new Account(RecordTypeId = personRecordTypeId, FirstName = 'Test', LastName = lastName);
        insert a;
        return [SELECT Id, PersonContactId FROM Account WHERE Id = :a.Id];
    }

    private static Account makeHouseholdAccount(String name) {
        Account a = new Account(Name = name);
        List<RecordType> householdTypes = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Account' AND IsPersonType = false AND Name LIKE '%Household%'
            LIMIT 1
        ];
        if (!householdTypes.isEmpty()) {
            a.RecordTypeId = householdTypes[0].Id;
        }
        insert a;
        return a;
    }
}
