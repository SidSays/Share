/**
 * User trigger handler for team-based provisioning.
 *
 * Integrate with the org's existing trigger framework: call these methods from the
 * framework's User trigger handler in the matching context (before insert, before update,
 * after insert, after update), or register this class with the framework according to its
 * conventions. Do not create a second User trigger.
 */
public inherited sharing class TeamProvisioningHandler {

    /** Users created with a Team get that team's Profile, Role and feature licenses. */
    public static void beforeInsert(List<User> newUsers) {
        List<User> scope = new List<User>();
        for (User u : newUsers) {
            if (String.isNotBlank(u.Team__c)) {
                scope.add(u);
            }
        }
        applyWithErrors(scope);
    }

    /** Runs only when Team__c changes, including when it is cleared. */
    public static void beforeUpdate(List<User> newUsers, Map<Id, User> oldMap) {
        List<User> scope = new List<User>();
        for (User u : newUsers) {
            if (teamChanged(u, oldMap.get(u.Id))) {
                scope.add(u);
            }
        }
        applyWithErrors(scope);
    }

    public static void afterInsert(List<User> newUsers) {
        Set<Id> ids = new Set<Id>();
        for (User u : newUsers) {
            if (String.isNotBlank(u.Team__c)) {
                ids.add(u.Id);
            }
        }
        TeamProvisioningService.enqueueSync(ids);
    }

    public static void afterUpdate(List<User> newUsers, Map<Id, User> oldMap) {
        Set<Id> ids = new Set<Id>();
        for (User u : newUsers) {
            if (teamChanged(u, oldMap.get(u.Id))) {
                ids.add(u.Id);
            }
        }
        TeamProvisioningService.enqueueSync(ids);
    }

    private static Boolean teamChanged(User newUser, User oldUser) {
        return oldUser == null || newUser.Team__c != oldUser.Team__c;
    }

    private static void applyWithErrors(List<User> scope) {
        if (scope.isEmpty()) {
            return;
        }
        Map<Integer, String> errors = TeamProvisioningService.applyUserFields(scope);
        for (Integer i : errors.keySet()) {
            scope[i].Team__c.addError(errors.get(i));
        }
    }
}
