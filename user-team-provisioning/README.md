# User Team Provisioning (Salesforce)

A small, metadata-driven framework that provisions user access from a single field. An admin sets **Team** on the User record and the automation applies that team's Profile, Role, feature licenses, permission sets and permission set groups, all defined in Custom Metadata.

## How it works

| Step | When | What happens |
|---|---|---|
| 1 | Before insert / before update, only when `Team__c` is set or changed | Looks up the `Team_Provisioning__mdt` record whose **Label equals the Team picklist API value**. Sets Profile, Role, Marketing User, Knowledge User and Service Cloud User on the record. Validates the Profile's license against the configured User License. Any problem blocks the save with a clear error on the Team field. |
| 2 | After save, in a Queueable | Makes the user's permission set and permission set group assignments **match the team exactly**: anything not in the team config is removed, anything missing is added. Any failure is sent to a single logging hook, `TeamProvisioningService.logError()`, for your org's logging framework. |
| 3 | On demand | `TeamProvisioningResyncBatch` re-applies config to existing team members after a metadata record changes. |

### Rules

- **Team is the source of truth.** Every time Team is set, Profile, Role, feature licenses and assignments are overwritten to match the team.
- **Team changed:** old team access is removed and new team access is added. Assignments the user already has and still needs are kept, so there is no gap in access.
- **Team cleared:** all removable permission set and permission set group assignments are removed and the three feature license checkboxes are cleared. **Profile and Role stay as they are.**
- **Never removed:** profile-owned permission sets and **managed package (namespaced)** permission sets and groups.
- **Blank Role in config:** the user's Role is cleared.
- **Missing or inactive config:** the save is blocked. The async sync never strips access because of missing config.
- **User License** is validation only. Salesforce derives the license from the Profile, so the framework checks that the Profile's license matches `Salesforce` or `Salesforce Platform` and blocks the save if not.

## Components

```
user-team-provisioning/
├── sfdx-project.json
└── force-app/main/default/
    ├── objects/User/fields/
    │   └── Team__c                      Restricted picklist (sample value: Sample_Team)
    ├── objects/Team_Provisioning__mdt/
    │   └── fields/
    │       ├── Active__c                Checkbox (default true)
    │       ├── Profile_Name__c          Text, required. Profile Name as shown in Setup
    │       ├── Role_Developer_Name__c   Text. UserRole DeveloperName
    │       ├── User_License__c          Picklist: Salesforce, Salesforce Platform
    │       ├── Permission_Sets__c       Long text, comma-separated API names
    │       ├── Permission_Set_Groups__c Long text, comma-separated DeveloperNames
    │       ├── Marketing_User__c        Checkbox
    │       ├── Knowledge_User__c        Checkbox
    │       └── Service_Cloud_User__c    Checkbox
    ├── customMetadata/
    │   └── Team_Provisioning.Sample_Team
    └── classes/
        ├── TeamProvisioningService      Core logic
        ├── TeamProvisioningHandler      Trigger handler methods
        ├── TeamProvisioningQueueable    Async assignment sync
        ├── TeamProvisioningResyncBatch  Resync batch + Flow action
        ├── TeamProvisioningTest         Unit tests (config injected in memory)
        └── TeamProvisioningConfigTest   Fails deploy if config is incomplete or invalid
```

## Hooking into your trigger framework

No User trigger is included, on purpose. Follow the trigger framework already implemented in your org: call the four handler methods from the framework's User handler in the matching contexts, or register `TeamProvisioningHandler` according to the framework's conventions. Do not create a second trigger on User.

```apex
// Inside your framework's User trigger handler (adapt to its method names):
public override void beforeInsert()  { TeamProvisioningHandler.beforeInsert((List<User>) Trigger.new); }
public override void beforeUpdate()  { TeamProvisioningHandler.beforeUpdate((List<User>) Trigger.new, (Map<Id, User>) Trigger.oldMap); }
public override void afterInsert()   { TeamProvisioningHandler.afterInsert((List<User>) Trigger.new); }
public override void afterUpdate()   { TeamProvisioningHandler.afterUpdate((List<User>) Trigger.new, (Map<Id, User>) Trigger.oldMap); }
```

If the org has no framework, a minimal trigger is:

```apex
trigger UserTrigger on User (before insert, before update, after insert, after update) {
    if (Trigger.isBefore && Trigger.isInsert) TeamProvisioningHandler.beforeInsert(Trigger.new);
    if (Trigger.isBefore && Trigger.isUpdate) TeamProvisioningHandler.beforeUpdate(Trigger.new, Trigger.oldMap);
    if (Trigger.isAfter  && Trigger.isInsert) TeamProvisioningHandler.afterInsert(Trigger.new);
    if (Trigger.isAfter  && Trigger.isUpdate) TeamProvisioningHandler.afterUpdate(Trigger.new, Trigger.oldMap);
}
```

## Hooking into your logging framework

Failures from the async permission set sync (and from the resync batch) go to one method, `TeamProvisioningService.logError(String message)`. It writes to the debug log until you replace the marked line with your org's logging framework call. Errors on Profile, Role or License are not logged: they block the User save and show on the Team field.

**Mixed DML warning.** `logError()` runs in the same transaction as the PermissionSetAssignment DML, which is a setup object. Your logger must not insert a custom log record directly at that point, or the transaction fails with a mixed DML error. Use a logger call that publishes a Platform Event (Publish Immediately behavior) or logs asynchronously.

## Setup

1. Deploy the source: `sf project deploy start --source-dir force-app --target-org <alias>`
2. Hook the handler into your trigger framework, and `logError()` into your logging framework (above).
3. Replace the sample picklist value with your teams. For each value, the **API name** must equal the **Label** of a `Team_Provisioning__mdt` record. Keep both within 40 characters (the Label limit).
4. Create one `Team_Provisioning__mdt` record per team.
5. Field-level security: give edit access on `Team__c` only to the admins who manage users.
6. Run all tests. `TeamProvisioningConfigTest` fails if any active Team value has no record, or a record points at a Profile, Role, permission set or group that does not exist.
7. After editing a team record, run the resync:

```apex
Database.executeBatch(new TeamProvisioningResyncBatch(), 50);               // all teams
Database.executeBatch(new TeamProvisioningResyncBatch('Sample_Team'), 50);  // one team
```

Or call the **Resync Team Provisioning** Apex action from a Flow.

## Design notes

- **Config is read with SOQL, not `getAll()` / `getInstance()`.** The static methods return only the first 255 characters of each field, which would silently cut off long permission set lists. The query runs once per transaction and is cached.
- **Two phases to avoid mixed DML.** Profile, Role and feature licenses are plain field values set in the before trigger with no DML. Assignments run in a Queueable so a User save that happens alongside DML on non-setup objects (Flows, data loads, tests) does not fail.
- **Partial success.** One failed assignment does not block the others. Each failure is passed to `logError()` with the user Id.
- **No recursion.** The resync batch updates users without changing `Team__c`, so the handler skips those updates.
- **Managed package items in config.** List them as `ns__Name`. They are assigned when configured but never removed by the overwrite.

## Known limits

- **Permission Set Licenses are not managed.** Permission sets that need a PSL fail to assign until the PSL is assigned manually. The failure is passed to `logError()` with the reason.
- **Feature licenses are counted.** Marketing, Knowledge and Service Cloud User fail if no seats are left. The save shows Salesforce's error.
- **Profile changes across licenses** are limited by Salesforce. Moving between Salesforce and Salesforce Platform is generally allowed. Other moves can be blocked by the platform.
- **Unmanaged standard permission sets** that Salesforce assigns automatically are treated like any other unmanaged assignment. If a team needs one, list it in the team config, or the overwrite will remove it.
- **Queueable limit.** If a transaction cannot enqueue another job (for example, inside an async context that has used its limit), the sync is skipped and `logError()` records the affected user Ids. Run the resync batch for those users.
- **Verification.** This source was reviewed but has not yet been compiled or run against an org. Deploy to a sandbox and run the tests first.
