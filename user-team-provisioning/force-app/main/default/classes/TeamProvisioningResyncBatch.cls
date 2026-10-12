/**
 * Re-applies team configuration to existing active users. Run after changing a
 * Team_Provisioning__mdt record so current team members pick up the change.
 *
 * Anonymous Apex:
 *   Database.executeBatch(new TeamProvisioningResyncBatch(), 50);               // all teams
 *   Database.executeBatch(new TeamProvisioningResyncBatch('Sample_Team'), 50);  // one team
 *
 * Flow: use the "Resync Team Provisioning" Apex action.
 */
public inherited sharing class TeamProvisioningResyncBatch implements Database.Batchable<SObject> {

    private final String team;

    public TeamProvisioningResyncBatch() {
        this(null);
    }

    public TeamProvisioningResyncBatch(String team) {
        this.team = team;
    }

    public Database.QueryLocator start(Database.BatchableContext context) {
        if (String.isBlank(team)) {
            return Database.getQueryLocator([
                SELECT Id FROM User WHERE IsActive = true AND Team__c != null
            ]);
        }
        return Database.getQueryLocator([
            SELECT Id FROM User WHERE IsActive = true AND Team__c = :team
        ]);
    }

    public void execute(Database.BatchableContext context, List<User> scope) {
        List<User> users = [
            SELECT Id, Team__c, ProfileId, UserRoleId,
                   UserPermissionsMarketingUser, UserPermissionsKnowledgeUser, UserPermissionsSupportUser
            FROM User WHERE Id IN :scope
        ];

        // Phase 1: Profile, Role, feature licenses
        Map<Integer, String> errors = TeamProvisioningService.applyUserFields(users);
        Map<Id, String> fieldErrors = new Map<Id, String>();
        List<User> toUpdate = new List<User>();
        for (Integer i = 0; i < users.size(); i++) {
            if (errors.containsKey(i)) {
                fieldErrors.put(users[i].Id, errors.get(i));
            } else {
                toUpdate.add(users[i]);
            }
        }
        Map<Id, String> teamByUserId = new Map<Id, String>();
        if (!toUpdate.isEmpty()) {
            // Team__c is unchanged, so the trigger handler skips these updates.
            Database.SaveResult[] results = Database.update(toUpdate, false);
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) {
                    teamByUserId.put(toUpdate[i].Id, toUpdate[i].Team__c);
                } else {
                    List<String> msgs = new List<String>();
                    for (Database.Error e : results[i].getErrors()) {
                        msgs.add(e.getMessage());
                    }
                    fieldErrors.put(toUpdate[i].Id, 'Could not update user fields: ' + String.join(msgs, '; '));
                }
            }
        }

        // Phase 2: assignments (all setup objects, so no mixed DML here)
        Map<Id, List<String>> issues = TeamProvisioningService.syncAssignments(teamByUserId);
        TeamProvisioningService.recordResults(issues, fieldErrors);
    }

    public void finish(Database.BatchableContext context) {
        System.debug(LoggingLevel.INFO, 'TeamProvisioningResyncBatch finished. Team filter: ' + (team == null ? 'all' : team));
    }

    /** Flow action. Pass one or more team values; pass a blank value to resync all teams. */
    @InvocableMethod(label='Resync Team Provisioning' description='Re-applies Team Provisioning configuration to active users on the given teams.')
    public static void resync(List<String> teams) {
        Set<String> unique = new Set<String>();
        for (String t : teams) {
            unique.add(String.isBlank(t) ? '' : t);
        }
        if (unique.contains('')) {
            Database.executeBatch(new TeamProvisioningResyncBatch(), 50);
            return;
        }
        for (String t : unique) {
            Database.executeBatch(new TeamProvisioningResyncBatch(t), 50);
        }
    }
}
