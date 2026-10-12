/**
 * Team-based user provisioning.
 *
 * User.Team__c (picklist) is the single source of truth for a user's access. Each picklist
 * value API name matches the Label (MasterLabel) of a Team_Provisioning__mdt record, which
 * defines the Profile, Role, feature licenses, permission sets and permission set groups.
 *
 * Two phases:
 *  1. applyUserFields(): before insert / before update. Sets Profile, Role and feature
 *     license checkboxes on the in-memory User records (no DML).
 *  2. syncAssignments(): runs asynchronously (Queueable) or from the resync batch. Makes the
 *     user's permission set and permission set group assignments match the team exactly.
 *     Profile-owned assignments and managed package (namespaced) assignments are never removed.
 *
 * Config is read with SOQL, not getAll()/getInstance(), because those static methods return
 * only the first 255 characters of each field and the permission set lists are Long Text.
 */
public inherited sharing class TeamProvisioningService {

    public static final String STATUS_PENDING = 'Pending';
    public static final String STATUS_SUCCESS = 'Success';
    public static final String STATUS_ERROR = 'Error';

    @TestVisible
    private static Map<String, Team_Provisioning__mdt> configCache;

    // ---------------------------------------------------------------------------------
    // Config
    // ---------------------------------------------------------------------------------

    /** Team configuration keyed by MasterLabel (equals the User.Team__c API value). */
    public static Map<String, Team_Provisioning__mdt> getConfigByTeam() {
        if (configCache == null) {
            configCache = new Map<String, Team_Provisioning__mdt>();
            for (Team_Provisioning__mdt rec : [
                SELECT MasterLabel, DeveloperName, Active__c, Profile_Name__c, Role_Developer_Name__c,
                       User_License__c, Permission_Sets__c, Permission_Set_Groups__c,
                       Marketing_User__c, Knowledge_User__c, Service_Cloud_User__c
                FROM Team_Provisioning__mdt
            ]) {
                configCache.put(rec.MasterLabel, rec);
            }
        }
        return configCache;
    }

    /** Splits a comma, semicolon or line separated list into trimmed, non-blank names. */
    public static Set<String> splitList(String raw) {
        Set<String> result = new Set<String>();
        if (String.isBlank(raw)) {
            return result;
        }
        for (String part : raw.split('[,;\\r\\n]')) {
            if (String.isNotBlank(part)) {
                result.add(part.trim());
            }
        }
        return result;
    }

    // ---------------------------------------------------------------------------------
    // Phase 1: User fields (before triggers / resync)
    // ---------------------------------------------------------------------------------

    /**
     * Applies Profile, Role and feature license checkboxes to in-memory users.
     * Returns validation errors keyed by the user's index in the list. The caller decides
     * how to surface them (addError in a trigger, status fields in the resync batch).
     *
     * Blank Team: Profile and Role stay as they are; feature license checkboxes are cleared.
     */
    public static Map<Integer, String> applyUserFields(List<User> users) {
        Map<Integer, String> errors = new Map<Integer, String>();
        if (users == null || users.isEmpty()) {
            return errors;
        }
        Map<String, Team_Provisioning__mdt> config = getConfigByTeam();

        Set<String> profileNames = new Set<String>();
        Set<String> roleNames = new Set<String>();
        for (User u : users) {
            Team_Provisioning__mdt rec = String.isBlank(u.Team__c) ? null : config.get(u.Team__c);
            if (rec == null) {
                continue;
            }
            if (String.isNotBlank(rec.Profile_Name__c)) {
                profileNames.add(rec.Profile_Name__c);
            }
            if (String.isNotBlank(rec.Role_Developer_Name__c)) {
                roleNames.add(rec.Role_Developer_Name__c);
            }
        }

        Map<String, Profile> profilesByName = new Map<String, Profile>();
        if (!profileNames.isEmpty()) {
            for (Profile p : [SELECT Id, Name, UserLicense.Name FROM Profile WHERE Name IN :profileNames]) {
                profilesByName.put(p.Name, p);
            }
        }
        Map<String, Id> roleIdsByName = new Map<String, Id>();
        if (!roleNames.isEmpty()) {
            for (UserRole r : [SELECT Id, DeveloperName FROM UserRole WHERE DeveloperName IN :roleNames]) {
                roleIdsByName.put(r.DeveloperName, r.Id);
            }
        }

        for (Integer i = 0; i < users.size(); i++) {
            User u = users[i];

            if (String.isBlank(u.Team__c)) {
                u.UserPermissionsMarketingUser = false;
                u.UserPermissionsKnowledgeUser = false;
                u.UserPermissionsSupportUser = false;
                u.Provisioning_Status__c = STATUS_PENDING;
                u.Provisioning_Message__c = 'Team cleared. Feature licenses removed; permission set and '
                    + 'permission set group removal queued. If this stays Pending, review the Apex Jobs page.';
                continue;
            }

            Team_Provisioning__mdt rec = config.get(u.Team__c);
            if (rec == null) {
                errors.put(i, 'No Team Provisioning record has the Label "' + u.Team__c + '".');
                continue;
            }
            if (!rec.Active__c) {
                errors.put(i, 'Team "' + u.Team__c + '" is inactive in Team Provisioning.');
                continue;
            }

            Profile p = profilesByName.get(rec.Profile_Name__c);
            if (p == null) {
                errors.put(i, 'Profile "' + rec.Profile_Name__c + '" configured for team "' + u.Team__c + '" was not found.');
                continue;
            }
            if (String.isNotBlank(rec.User_License__c) && p.UserLicense.Name != rec.User_License__c) {
                errors.put(i, 'Profile "' + p.Name + '" uses the "' + p.UserLicense.Name + '" license, but team "'
                    + u.Team__c + '" expects "' + rec.User_License__c + '".');
                continue;
            }

            Id roleId = null;
            if (String.isNotBlank(rec.Role_Developer_Name__c)) {
                roleId = roleIdsByName.get(rec.Role_Developer_Name__c);
                if (roleId == null) {
                    errors.put(i, 'Role "' + rec.Role_Developer_Name__c + '" configured for team "' + u.Team__c + '" was not found.');
                    continue;
                }
            }

            u.ProfileId = p.Id;
            u.UserRoleId = roleId;
            u.UserPermissionsMarketingUser = rec.Marketing_User__c;
            u.UserPermissionsKnowledgeUser = rec.Knowledge_User__c;
            u.UserPermissionsSupportUser = rec.Service_Cloud_User__c;
            u.Provisioning_Status__c = STATUS_PENDING;
            u.Provisioning_Message__c = 'Profile, Role and feature licenses applied for team "' + u.Team__c
                + '". Permission set sync queued. If this stays Pending, review the Apex Jobs page.';
        }
        return errors;
    }

    // ---------------------------------------------------------------------------------
    // Phase 2: permission set and permission set group assignments (async / batch)
    // ---------------------------------------------------------------------------------

    /** Queues the assignment sync. Called from after insert / after update. */
    public static void enqueueSync(Set<Id> userIds) {
        if (userIds == null || userIds.isEmpty()) {
            return;
        }
        if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new TeamProvisioningQueueable(userIds));
        } else {
            // Status stays Pending with a message pointing to the resync batch.
            System.debug(LoggingLevel.WARN, 'TeamProvisioning: Queueable limit reached; run TeamProvisioningResyncBatch for '
                + userIds.size() + ' user(s).');
        }
    }

    /** Syncs assignments and writes the result to the users' status fields. */
    public static void syncAndRecord(Map<Id, String> teamByUserId) {
        Map<Id, List<String>> issues = syncAssignments(teamByUserId);
        recordResults(issues, new Map<Id, String>());
    }

    /**
     * Makes each user's permission set and permission set group assignments match the team.
     * A blank team removes all removable assignments.
     * Never removes profile-owned assignments or managed package (namespaced) assignments.
     * Returns issues per user (an empty list means success).
     */
    public static Map<Id, List<String>> syncAssignments(Map<Id, String> teamByUserId) {
        Map<Id, List<String>> issuesByUser = new Map<Id, List<String>>();
        if (teamByUserId == null || teamByUserId.isEmpty()) {
            return issuesByUser;
        }
        Map<String, Team_Provisioning__mdt> config = getConfigByTeam();

        // 1. Desired state per user
        Map<Id, Set<String>> desiredPs = new Map<Id, Set<String>>();
        Map<Id, Set<String>> desiredPsg = new Map<Id, Set<String>>();
        Set<String> psBareNames = new Set<String>();
        Set<String> psgBareNames = new Set<String>();

        for (Id userId : teamByUserId.keySet()) {
            issuesByUser.put(userId, new List<String>());
            String team = teamByUserId.get(userId);
            Set<String> ps = new Set<String>();
            Set<String> psg = new Set<String>();
            if (String.isNotBlank(team)) {
                Team_Provisioning__mdt rec = config.get(team);
                if (rec == null || !rec.Active__c) {
                    // Never strip access because of missing or inactive config.
                    issuesByUser.get(userId).add('Team "' + team + '" has no active Team Provisioning record. Assignments not changed.');
                    continue;
                }
                ps = splitList(rec.Permission_Sets__c);
                psg = splitList(rec.Permission_Set_Groups__c);
            }
            desiredPs.put(userId, ps);
            desiredPsg.put(userId, psg);
            for (String n : ps) {
                psBareNames.add(bareName(n));
            }
            for (String n : psg) {
                psgBareNames.add(bareName(n));
            }
        }
        if (desiredPs.isEmpty()) {
            return issuesByUser;
        }

        // 2. Resolve names to Ids
        Map<String, Id> psIdByName = new Map<String, Id>();
        if (!psBareNames.isEmpty()) {
            for (PermissionSet ps : [
                SELECT Id, Name, NamespacePrefix FROM PermissionSet
                WHERE Name IN :psBareNames AND IsOwnedByProfile = false AND PermissionSetGroupId = null
            ]) {
                psIdByName.put(qualifiedName(ps.NamespacePrefix, ps.Name), ps.Id);
            }
        }
        Map<String, Id> psgIdByName = new Map<String, Id>();
        if (!psgBareNames.isEmpty()) {
            for (PermissionSetGroup g : [
                SELECT Id, DeveloperName, NamespacePrefix FROM PermissionSetGroup WHERE DeveloperName IN :psgBareNames
            ]) {
                psgIdByName.put(qualifiedName(g.NamespacePrefix, g.DeveloperName), g.Id);
            }
        }

        // 3. Compare with current assignments
        Set<Id> scopeIds = desiredPs.keySet();
        List<PermissionSetAssignment> toDelete = new List<PermissionSetAssignment>();
        Map<Id, Set<String>> presentPs = new Map<Id, Set<String>>();
        Map<Id, Set<String>> presentPsg = new Map<Id, Set<String>>();
        for (Id userId : scopeIds) {
            presentPs.put(userId, new Set<String>());
            presentPsg.put(userId, new Set<String>());
        }

        for (PermissionSetAssignment psa : [
            SELECT Id, AssigneeId, PermissionSetId, PermissionSetGroupId,
                   PermissionSet.Name, PermissionSet.NamespacePrefix,
                   PermissionSetGroup.DeveloperName, PermissionSetGroup.NamespacePrefix
            FROM PermissionSetAssignment
            WHERE AssigneeId IN :scopeIds AND PermissionSet.IsOwnedByProfile = false
        ]) {
            Boolean isGroup = psa.PermissionSetGroupId != null;
            String ns = isGroup ? psa.PermissionSetGroup.NamespacePrefix : psa.PermissionSet.NamespacePrefix;
            String key = isGroup
                ? qualifiedName(ns, psa.PermissionSetGroup.DeveloperName)
                : qualifiedName(ns, psa.PermissionSet.Name);
            Set<String> desired = isGroup ? desiredPsg.get(psa.AssigneeId) : desiredPs.get(psa.AssigneeId);

            if (desired.contains(key)) {
                if (isGroup) {
                    presentPsg.get(psa.AssigneeId).add(key);
                } else {
                    presentPs.get(psa.AssigneeId).add(key);
                }
            } else if (String.isBlank(ns)) {
                toDelete.add(psa);
            }
            // Managed package (namespaced) assignments are left untouched.
        }

        // 4. Build inserts for missing assignments
        List<PermissionSetAssignment> toInsert = new List<PermissionSetAssignment>();
        for (Id userId : scopeIds) {
            for (String name : desiredPs.get(userId)) {
                if (presentPs.get(userId).contains(name)) {
                    continue;
                }
                Id psId = psIdByName.get(name);
                if (psId == null) {
                    issuesByUser.get(userId).add('Permission set "' + name + '" not found.');
                } else {
                    toInsert.add(new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = psId));
                }
            }
            for (String name : desiredPsg.get(userId)) {
                if (presentPsg.get(userId).contains(name)) {
                    continue;
                }
                Id psgId = psgIdByName.get(name);
                if (psgId == null) {
                    issuesByUser.get(userId).add('Permission set group "' + name + '" not found.');
                } else {
                    toInsert.add(new PermissionSetAssignment(AssigneeId = userId, PermissionSetGroupId = psgId));
                }
            }
        }

        // 5. DML with partial success so one bad assignment does not block the rest
        if (!toDelete.isEmpty()) {
            Database.DeleteResult[] results = Database.delete(toDelete, false);
            for (Integer i = 0; i < results.size(); i++) {
                if (!results[i].isSuccess()) {
                    issuesByUser.get(toDelete[i].AssigneeId).add('Could not remove assignment ' + toDelete[i].Id + ': '
                        + joinErrors(results[i].getErrors()));
                }
            }
        }
        if (!toInsert.isEmpty()) {
            Database.SaveResult[] results = Database.insert(toInsert, false);
            for (Integer i = 0; i < results.size(); i++) {
                if (!results[i].isSuccess()) {
                    PermissionSetAssignment psa = toInsert[i];
                    String target = psa.PermissionSetGroupId != null
                        ? 'permission set group ' + psa.PermissionSetGroupId
                        : 'permission set ' + psa.PermissionSetId;
                    issuesByUser.get(psa.AssigneeId).add('Could not assign ' + target + ': ' + joinErrors(results[i].getErrors()));
                }
            }
        }
        return issuesByUser;
    }

    /**
     * Writes Provisioning_Status__c and Provisioning_Message__c. The update does not change
     * Team__c, so the trigger handler skips it and there is no recursion.
     * fieldErrors holds Phase 1 errors from the resync batch (user Id to message).
     */
    public static void recordResults(Map<Id, List<String>> assignmentIssues, Map<Id, String> fieldErrors) {
        Map<Id, User> updates = new Map<Id, User>();
        for (Id userId : assignmentIssues.keySet()) {
            List<String> issues = assignmentIssues.get(userId);
            Boolean ok = issues.isEmpty();
            updates.put(userId, new User(
                Id = userId,
                Provisioning_Status__c = ok ? STATUS_SUCCESS : STATUS_ERROR,
                Provisioning_Message__c = truncate(ok
                    ? 'Provisioning completed ' + System.now().format() + '.'
                    : String.join(issues, '\n'))
            ));
        }
        for (Id userId : fieldErrors.keySet()) {
            updates.put(userId, new User(
                Id = userId,
                Provisioning_Status__c = STATUS_ERROR,
                Provisioning_Message__c = truncate(fieldErrors.get(userId))
            ));
        }
        if (!updates.isEmpty()) {
            Database.SaveResult[] results = Database.update(updates.values(), false);
            for (Database.SaveResult r : results) {
                if (!r.isSuccess()) {
                    System.debug(LoggingLevel.ERROR, 'TeamProvisioning: could not write status for ' + r.getId() + ': '
                        + joinErrors(r.getErrors()));
                }
            }
        }
    }

    // ---------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------

    /** "ns__Name" -> "Name". Developer names cannot contain "__", so "__" marks a namespace. */
    @TestVisible
    private static String bareName(String name) {
        Integer idx = name.indexOf('__');
        return idx > 0 ? name.substring(idx + 2) : name;
    }

    @TestVisible
    private static String qualifiedName(String ns, String name) {
        return String.isBlank(ns) ? name : ns + '__' + name;
    }

    private static String joinErrors(List<Database.Error> errs) {
        List<String> parts = new List<String>();
        for (Database.Error e : errs) {
            parts.add(e.getMessage());
        }
        return String.join(parts, '; ');
    }

    private static String truncate(String value) {
        return value != null && value.length() > 32000 ? value.substring(0, 32000) : value;
    }
}
