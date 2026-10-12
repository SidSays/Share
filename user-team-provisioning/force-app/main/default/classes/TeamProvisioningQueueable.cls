/**
 * Syncs permission set and permission set group assignments after a Team__c change.
 * Runs in its own transaction to avoid mixed DML errors when the User save happens
 * alongside DML on non-setup objects.
 */
public inherited sharing class TeamProvisioningQueueable implements Queueable {

    private final Set<Id> userIds;

    public TeamProvisioningQueueable(Set<Id> userIds) {
        this.userIds = userIds;
    }

    public void execute(QueueableContext context) {
        // Re-read Team__c so the job applies the latest value, even if it changed again.
        Map<Id, String> teamByUserId = new Map<Id, String>();
        for (User u : [SELECT Id, Team__c FROM User WHERE Id IN :userIds]) {
            teamByUserId.put(u.Id, u.Team__c);
        }
        TeamProvisioningService.syncAndLog(teamByUserId);
    }
}
