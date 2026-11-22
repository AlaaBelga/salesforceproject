import { LightningElement, api } from 'lwc';
import getSummary from '@salesforce/apex/ParticipantSummaryController.getSummary';

// Read only. This component never writes, edits or deletes a record.

const SIGN_UP_LABELS = {
    Enrolled: 'Signed up',
    Completed: 'Attended',
    Absent: 'Missed',
    Excused: 'Excused'
};

const SIGN_UP_BADGES = {
    Enrolled: 'slds-badge slds-theme_info',
    Completed: 'slds-badge slds-theme_success',
    Absent: 'slds-badge slds-theme_warning',
    Excused: 'slds-badge'
};

const NOT_ELIGIBLE_STATUSES = ['Withdrawn', 'Denied'];

// Apex sends Date values as "YYYY-MM-DD". Build a local date so the day never shifts.
function parseDateOnly(value) {
    if (!value) {
        return null;
    }
    const [year, month, day] = value.split('-').map(Number);
    return new Date(year, month - 1, day);
}

function formatDate(date) {
    if (!date) {
        return '';
    }
    return new Intl.DateTimeFormat(undefined, {
        weekday: 'short',
        day: 'numeric',
        month: 'short',
        year: 'numeric'
    }).format(date);
}

function formatDateTime(value) {
    if (!value) {
        return '';
    }
    return new Intl.DateTimeFormat(undefined, {
        weekday: 'short',
        day: 'numeric',
        month: 'short',
        hour: 'numeric',
        minute: '2-digit'
    }).format(new Date(value));
}

function plural(count, one, many) {
    return `${count} ${count === 1 ? one : many}`;
}

function daysAgoText(days) {
    if (days === 0) {
        return 'today';
    }
    if (days === 1) {
        return 'yesterday';
    }
    return `${days} days ago`;
}

function buildSessionRow(session) {
    return {
        key: session.sessionId,
        when: formatDateTime(session.startDateTime),
        name: session.sessionName,
        label: SIGN_UP_LABELS[session.signUpStatus] || session.signUpStatus,
        badgeClass: SIGN_UP_BADGES[session.signUpStatus] || 'slds-badge'
    };
}

function buildHousehold(summary) {
    const household = summary.household;
    if (!household) {
        return { hasHousehold: false, householdName: null };
    }
    const hasSize = household.size !== null && household.size !== undefined;
    let sizeNote = 'Household size not recorded. Ask at the door.';
    if (hasSize && household.sizeSource === 'visit') {
        sizeNote = `As reported at the last visit (${formatDate(parseDateOnly(household.sizeAsOf))}). Ask again, it can change.`;
    } else if (hasSize) {
        sizeNote = 'From the first-day intake. It may be out of date, so ask at the door.';
    }
    return {
        hasHousehold: true,
        householdName: household.name,
        householdSizeText: hasSize ? `Household of ${household.size}` : 'Size not recorded',
        bagsText: household.bags ? plural(household.bags, 'bag', 'bags') : '',
        sizeNote,
        multipleHouseholds: summary.householdCount > 1,
        multipleHouseholdsText: `This person belongs to ${summary.householdCount} households. Showing the first.`
    };
}

function buildPantry(pantry) {
    const eligible =
        pantry.isEnrolled && pantry.isActive && !NOT_ELIGIBLE_STATUSES.includes(pantry.enrollmentStatus);

    let answerText;
    let answerClass;
    if (eligible) {
        answerText = 'Yes. The household is enrolled for Saturdays.';
        answerClass = 'answer answer_yes';
    } else if (pantry.isEnrolled) {
        answerText = `Pantry enrollment is ${pantry.enrollmentStatus || 'not active'}.`;
        answerClass = 'answer answer_check';
    } else {
        answerText =
            'No pantry enrollment on file. Anyone can still be served: this only shows what is recorded.';
        answerClass = 'answer answer_none';
    }

    const weeks = pantry.weeks || [];
    const weekCells = weeks.map((visited, index) => {
        const weeksAgo = weeks.length - 1 - index;
        const when = weeksAgo === 0 ? 'This week' : plural(weeksAgo, 'week ago', 'weeks ago');
        return {
            key: `week-${index}`,
            className: visited ? 'week-cell week-cell_on' : 'week-cell',
            title: `${when}: ${visited ? 'visited' : 'no visit'}`
        };
    });

    const lastVisit = parseDateOnly(pantry.lastVisitDate);
    return {
        answerText,
        answerClass,
        hasVisits: pantry.hasVisitRecords,
        lastVisitText: lastVisit
            ? `Last visit: ${formatDate(lastVisit)} (${daysAgoText(pantry.daysSinceLastVisit)})`
            : '',
        noVisitsText: pantry.isEnrolled
            ? 'No visits recorded in Salesforce yet. Earlier visits may be on the paper sheets.'
            : '',
        weekCells,
        visitsText: `${plural(pantry.visitsInWindow, 'visit', 'visits')} in the last ${weeks.length} weeks`,
        showLapsed: pantry.isLapsed,
        lapsedText: `No visit for ${pantry.daysSinceLastVisit} days. Worth a check-in call.`
    };
}

function buildClasses(classes) {
    const enrollments = (classes.enrollments || []).map((enrollment) => ({
        key: enrollment.enrollmentId,
        title: enrollment.programName || 'Class enrollment',
        statusText: enrollment.status || '',
        startText: enrollment.startDate ? `Started ${formatDate(parseDateOnly(enrollment.startDate))}` : '',
        progressText: `${enrollment.attended} of ${enrollment.required} sessions toward the certificate`,
        progressNote: enrollment.certificateMet
            ? 'Certificate requirement met.'
            : `${plural(enrollment.totalSessions, 'session', 'sessions')} in the course.`,
        percent: Math.min(100, Math.round((enrollment.attended / enrollment.required) * 100))
    }));

    const upcoming = (classes.upcoming || []).map(buildSessionRow);
    const recent = (classes.recent || []).map(buildSessionRow);
    const next = upcoming[0];
    const last = classes.lastSession ? buildSessionRow(classes.lastSession) : null;

    return {
        hasEnrollment: enrollments.length > 0,
        enrollments,
        nextText: next
            ? `Next class: ${next.when}`
            : 'Not signed up for an upcoming class.',
        nextClass: Boolean(next),
        lastText: last ? `Last class (${last.when}): ${last.label}` : 'No class sessions recorded yet.',
        recent,
        hasRecent: recent.length > 0
    };
}

function buildView(summary) {
    return {
        nothingOnFile: summary.nothingOnFile,
        title: summary.personName || (summary.household ? summary.household.name : 'Participant'),
        ...buildHousehold(summary),
        pantry: buildPantry(summary.pantry),
        classes: buildClasses(summary.classes)
    };
}

function reduceError(error) {
    if (error && error.body && error.body.message) {
        return error.body.message;
    }
    if (error && error.message) {
        return error.message;
    }
    return 'Something went wrong while loading the summary.';
}

export default class ParticipantSummary extends LightningElement {
    @api recordId;

    isLoading = true;
    errorMessage;
    view;

    connectedCallback() {
        this.load();
    }

    handleRefresh() {
        this.load();
    }

    async load() {
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            const summary = await getSummary({ recordId: this.recordId });
            this.view = buildView(summary);
        } catch (error) {
            this.view = undefined;
            this.errorMessage = reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    get showContent() {
        return !this.isLoading && !this.errorMessage && Boolean(this.view);
    }

    get showEmptyState() {
        return this.showContent && this.view.nothingOnFile;
    }

    get showDetails() {
        return this.showContent && !this.view.nothingOnFile;
    }
}
