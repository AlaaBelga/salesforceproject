// System-wide checks must see bookings even when the current user cannot read their records.
public without sharing class ClassSessionBookingRules {
    private static final String CLASS_PROGRAM = 'Cooking and Nutrition Class';
    private static final Integer MAX_SEATS = 12;

    public static void checkBookings(
        List<BenefitDisbursement> incoming,
        Map<Id, BenefitDisbursement> previous
    ) {
        List<BenefitDisbursement> candidates = new List<BenefitDisbursement>();
        Set<Id> sessionIds = new Set<Id>();
        for (BenefitDisbursement row : incoming) {
            if (row.BenefitSessionId == null || row.DisbursementStatus != 'Enrolled') {
                continue;
            }
            BenefitDisbursement old = previous == null ? null : previous.get(row.Id);
            if (old != null && old.BenefitSessionId == row.BenefitSessionId
                && old.RecipientId == row.RecipientId && old.DisbursementStatus == 'Enrolled') {
                continue;
            }
            candidates.add(row);
            sessionIds.add(row.BenefitSessionId);
        }
        if (sessionIds.isEmpty()) {
            return;
        }

        // Serialize competing sign-ups on the session, then read the committed bookings.
        Map<Id, BenefitSession> classSessions = new Map<Id, BenefitSession>([
            SELECT Id FROM BenefitSession
            WHERE Id IN :sessionIds AND BenefitSchedule.Benefit.Program.Name = :CLASS_PROGRAM
            FOR UPDATE
        ]);
        if (classSessions.isEmpty()) {
            return;
        }

        Set<Id> classSessionIds = classSessions.keySet();
        Map<Id, Set<Id>> occupied = new Map<Id, Set<Id>>();
        for (Id sessionId : classSessionIds) {
            occupied.put(sessionId, new Set<Id>());
        }
        for (AggregateResult existing : [
            SELECT BenefitSessionId sessionId, RecipientId participantId
            FROM BenefitDisbursement
            WHERE BenefitSessionId IN :classSessionIds AND RecipientId != null
                AND DisbursementStatus IN ('Enrolled', 'Completed', 'Absent', 'Excused')
            GROUP BY BenefitSessionId, RecipientId
        ]) {
            occupied.get((Id) existing.get('sessionId')).add((Id) existing.get('participantId'));
        }
        for (BenefitDisbursement row : candidates) {
            Set<Id> participants = occupied.get(row.BenefitSessionId);
            if (participants == null) {
                continue;
            }
            if (row.RecipientId == null) {
                row.addError('Select a participant for this cooking class session.');
            } else if (participants.contains(row.RecipientId)) {
                row.addError('This participant is already signed up for this cooking class session.');
            } else if (participants.size() >= MAX_SEATS) {
                row.addError('This cooking class session is full. Choose another session.');
            } else {
                participants.add(row.RecipientId);
            }
        }
    }
}
