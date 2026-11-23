# Participant Summary (Salesforce Nonprofit Cloud)

A read-only Lightning Web Component that shows, on one screen and on a person's record: their household and household size, pantry and class enrollments, class sessions, and the last pantry visit.

**Status: deployed and tested in a Nonprofit Cloud trial org.** The component runs on the Person Account page with demo data. The class booking trigger refuses a 13th participant for a session and refuses a repeat sign-up for the same person.

## Who it is for and what it shows

| Question | Where the answer is |
|---|---|
| Who is this, and how many bags? | Header: name, household name (carries the street), household size, bag count |
| Can the family still come Saturday? | Pantry block, top line |
| When did they last come? Are they regular? | Pantry block: last visit, eight-week strip, check-in flag after 28 days without a visit |
| Am I signed up? When is my next class? | Class block, top line (from upcoming sessions, not from enrollment status) |
| Did they come last time? How many toward the certificate? | Class block: last class, progress out of 10 |
| A brand-new person | A plain "Nothing on file yet" message, never a blank page |

## What it deliberately leaves off

The tablet is readable by everyone in line. The Apex controller never queries birthdate, phone, email, gender identity or any free-text notes, so they cannot reach the browser. It also has no edit controls and no DML. Anyone can still be served whatever the screen shows; the footer says so.

## How it reads your data

| Thing | Where it lives |
|---|---|
| Person | Person Account |
| Household | Business Account + Party Relationship Group (Type = Household) |
| Membership | Account Contact Relationship from the person's contact to the household account |
| Pantry enrollment | Program Enrollment on the household account |
| Class enrollment | Program Enrollment on the person |
| Class sign-up and attendance | Benefit Disbursement with a Benefit Session (Enrolled, Completed, Absent, Excused) |
| Pantry visit | Benefit Disbursement with no session, status Completed; its Recipient Count is the household size at that visit |

Household size shown is the last visit's recipient count when there is one, otherwise the group's Group Size labelled "from the first-day intake". Group Size is documented as a count of active members, so treat it as a starting figure.

Programs are told apart by keyword in their name ("pantry" and "class"). Everything else you may want to change is a constant at the top of `ParticipantSummaryController.cls`: certificate sessions (10), course sessions (12), weeks shown (8), days until the check-in flag (28).

## Deploy

With the Salesforce CLI:

```
sf org login web --alias harbor-trial
sf project deploy start --source-dir force-app --target-org harbor-trial
sf org assign permset --name Participant_Summary_Access --target-org harbor-trial
sf apex run test --class-names ParticipantSummaryControllerTest --result-format human --wait 10 --target-org harbor-trial
```

Or in VS Code with the Salesforce Extension Pack: authorize the org, then right-click `force-app` and choose "SFDX: Deploy Source to Org".

Then in the org: open a Person Account, click the gear, **Edit Page**, drag **Participant Summary** onto the page, Save, and activate it as the org default for Accounts.

Users also need read access to the objects and fields above. The query runs in user mode, so a volunteer without access to a field gets a clear error instead of hidden data.

## If the first deploy fails

- **A field "does not exist"** (for example the session or program enrollment fields on Benefit Disbursement). The Salesforce docs mark several of these as requiring the Data Protection and Privacy setting. Check the field in Object Manager and look for that setting in Setup.
- **`IsPersonAccount` or `PersonContactId` not found.** Person Accounts are not enabled in that org.
- **Test failures in the record tests.** They need Person Accounts and Contacts to Multiple Accounts. The tests that need no data (bags, weeks, lapsed flag, program keywords) should pass regardless.
- **The summary loads but shows nothing for a person you know has data.** The queries assume the model in the table above. If sign-ups or visits are stored differently, adjust the `BenefitDisbursement` query in `buildSummary`.

## Not built

- The standalone offline pantry log (`offline-pantry.html`) holds entries in memory until CSV export; exported pickups require manual entry in Salesforce. It does not sync.
- Jest tests for the component.
- A "hide details" toggle for the tablet at the door.

## Class booking checks and offline pantry log

The class booking trigger is scoped to the program named Cooking and Nutrition Class. It checks enrolled Benefit Disbursements by session and recipient and applies the case limit of 12 distinct participants. It locks the session before reading bookings so concurrent sign-ups cannot both claim the final seat. Existing attendance statuses count as used seats. Other programs and pantry pickups are outside the trigger's scope.

Validated in the Nonprofit Cloud trial: the standard Add Participants action reaches the trigger and shows the capacity error. The trigger also refuses a repeat sign-up for the same participant and session.

Open **offline-pantry.html** from a downloaded copy of this ZIP before going outside. It runs without a connection. Use household references or anonymous rows and export the CSV before closing it. When back online, reconcile that file and enter pickups in Salesforce with the original pickup dates. The log lives in the open page until exported and requires manual reconciliation. It never sends data to Salesforce.
