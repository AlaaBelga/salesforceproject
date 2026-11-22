trigger ClassSessionBooking on BenefitDisbursement (before insert, before update) {
    ClassSessionBookingRules.checkBookings(Trigger.new, Trigger.oldMap);
}
