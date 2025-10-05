import csv
import re
from collections import OrderedDict

EPIC_LABELS = {
    'E1': 'epic:TicketIntakeLifecycle',
    'E2': 'epic:ContactAccess',
    'E3': 'epic:KnowledgeBase',
    'E4': 'epic:AutomationSLA',
    'E5': 'epic:AIAssistance',
    'E6': 'epic:EmailOps',
    'E7': 'epic:ReportingAnalytics',
    'E8': 'epic:Integrations',
    'E9': 'epic:AdminPortal',
    'E10': 'epic:SecurityCompliance',
    'E11': 'epic:DevOpsInfra',
}

TYPE_LABELS = {
    'analysis': 'type:Analysis',
    'implementation': 'type:Implementation',
}

PRIORITY_LABELS = {
    'high': 'priority:P0',
    'medium': 'priority:P1',
}

AREA_LABELS = {
    'architecture': 'area:Architecture',
    'backend': 'area:Backend',
    'frontend': 'area:Frontend',
    'product': 'area:Product',
    'devops': 'area:DevOps',
    'compliance': 'area:Compliance',
    'security': 'area:Security',
}

ACCEPTANCE_TEMPLATE = [
    '- [ ] CRUD/API/Filament with RBAC',
    '- [ ] Tenant/brand scope enforced',
    '- [ ] Audit log entries',
    '- [ ] Indexes on foreign keys',
    '- [ ] Tests (happy + error paths)',
]

issue_pattern = re.compile(r'- Issue \*\*(E\d+-F\d+-I\d+) - (.+?)\*\*')
label_pattern = re.compile(r'\{([^}]+)\}')

issues = OrderedDict()

with open('wbs_raw.txt', encoding='utf-8') as fh:
    lines = [line.rstrip('\n') for line in fh]

i = 0
while i < len(lines):
    line = lines[i]
    match = issue_pattern.search(line)
    if not match:
        i += 1
        continue

    issue_id, raw_title = match.groups()
    title = raw_title.strip()

    # Expect labels line next
    i += 1
    labels_line = lines[i].strip()
    label_match = label_pattern.search(labels_line)
    if not label_match:
        raise ValueError(f'Missing labels for {issue_id}')
    label_parts = [part.strip() for part in label_match.group(1).split(',')]
    if len(label_parts) != 4:
        raise ValueError(f'Unexpected label schema for {issue_id}: {label_parts}')

    epic_key = issue_id.split('-')[0]
    epic_label = EPIC_LABELS[epic_key]

    type_label = TYPE_LABELS.get(label_parts[1].lower())
    if not type_label:
        raise ValueError(f'Unknown type label "{label_parts[1]}" for {issue_id}')

    priority_label = PRIORITY_LABELS.get(label_parts[2].lower())
    if not priority_label:
        raise ValueError(f'Unknown priority label "{label_parts[2]}" for {issue_id}')

    area_label = AREA_LABELS.get(label_parts[3].lower())
    if not area_label:
        raise ValueError(f'Unknown area label "{label_parts[3]}" for {issue_id}')

    # Acceptance Criteria header line expected next
    i += 1  # move to acceptance criteria header
    if 'Acceptance Criteria' not in lines[i]:
        raise ValueError(f'Expected Acceptance Criteria for {issue_id}')

    acceptance_items = []
    i += 1
    while i < len(lines) and lines[i].startswith('      - '):
        acceptance_items.append(lines[i].split('      - ', 1)[1].strip())
        i += 1

    dependencies_line = lines[i].strip()
    if not dependencies_line.startswith('- Dependencies:'):
        raise ValueError(f'Expected Dependencies for {issue_id}')
    dependencies_value = dependencies_line.split(':', 1)[1].strip()

    i += 1
    milestone_line = lines[i].strip()
    if not milestone_line.startswith('- Milestone:'):
        raise ValueError(f'Expected Milestone for {issue_id}')
    milestone_value = milestone_line.split(':', 1)[1].strip()

    summary = f"{title}. {' '.join(acceptance_items)}"
    scope_lines = [f"- [ ] {item}" for item in acceptance_items]

    body_sections = [
        '### Summary',
        summary.strip(),
        '',
        '### Scope',
        *(scope_lines if scope_lines else ['- [ ] Define detailed scope items']),
        '',
        '### Acceptance Criteria',
        *ACCEPTANCE_TEMPLATE,
        '',
        '### Notes',
        '- tenant-scope, RBAC, audit-log',
        '- Observability: JSON logs + correlation-id',
        f'- Dependencies: {dependencies_value}',
    ]
    body = '\n'.join(body_sections)

    labels_value = ';'.join([epic_label, type_label, priority_label, area_label])

    full_title = f"{issue_id}: {title}"

    issues[issue_id] = {
        'id': issue_id,
        'title': full_title,
        'body': body,
        'labels': labels_value,
        'milestone': milestone_value,
    }

    i += 1

with open('issues.csv', 'w', newline='', encoding='utf-8') as csvfile:
    writer = csv.DictWriter(csvfile, fieldnames=['id', 'title', 'body', 'labels', 'milestone'])
    writer.writeheader()
    for issue in issues.values():
        writer.writerow(issue)
