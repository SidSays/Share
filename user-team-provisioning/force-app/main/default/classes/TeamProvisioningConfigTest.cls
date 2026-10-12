/**
 * Configuration guard. Fails deployment when:
 *  - an active User.Team__c value has no Team_Provisioning__mdt record with a matching Label
 *  - a record references a Profile, Role, permission set or permission set group that does not exist
 *  - a record's Profile license does not match its User License value
 */
@IsTest
private class TeamProvisioningConfigTest {

    @IsTest
    static void everyTeamValueHasValidConfig() {
        Map<String, Team_Provisioning__mdt> config = TeamProvisioningService.getConfigByTeam();
        List<String> problems = new List<String>();

        for (Schema.PicklistEntry e : User.Team__c.getDescribe().getPicklistValues()) {
            if (e.isActive() && !config.containsKey(e.getValue())) {
                problems.add('Team value "' + e.getValue() + '" has no Team Provisioning record with that Label.');
            }
        }

        Set<String> profiles = new Set<String>();
        Set<String> roles = new Set<String>();
        Set<String> permSets = new Set<String>();
        Set<String> groups = new Set<String>();
        for (Team_Provisioning__mdt rec : config.values()) {
            profiles.add(rec.Profile_Name__c);
            if (String.isNotBlank(rec.Role_Developer_Name__c)) {
                roles.add(rec.Role_Developer_Name__c);
            }
            permSets.addAll(TeamProvisioningService.splitList(rec.Permission_Sets__c));
            groups.addAll(TeamProvisioningService.splitList(rec.Permission_Set_Groups__c));
        }

        Map<String, String> licenseByProfile = new Map<String, String>();
        for (Profile p : [SELECT Name, UserLicense.Name FROM Profile WHERE Name IN :profiles]) {
            licenseByProfile.put(p.Name, p.UserLicense.Name);
        }
        Set<String> foundRoles = new Set<String>();
        for (UserRole r : [SELECT DeveloperName FROM UserRole WHERE DeveloperName IN :roles]) {
            foundRoles.add(r.DeveloperName);
        }
        Set<String> bare = new Set<String>();
        for (String n : permSets) {
            bare.add(TeamProvisioningService.bareName(n));
        }
        Set<String> foundPs = new Set<String>();
        for (PermissionSet ps : [SELECT Name, NamespacePrefix FROM PermissionSet WHERE Name IN :bare AND IsOwnedByProfile = false]) {
            foundPs.add(TeamProvisioningService.qualifiedName(ps.NamespacePrefix, ps.Name));
        }
        bare = new Set<String>();
        for (String n : groups) {
            bare.add(TeamProvisioningService.bareName(n));
        }
        Set<String> foundGroups = new Set<String>();
        for (PermissionSetGroup g : [SELECT DeveloperName, NamespacePrefix FROM PermissionSetGroup WHERE DeveloperName IN :bare]) {
            foundGroups.add(TeamProvisioningService.qualifiedName(g.NamespacePrefix, g.DeveloperName));
        }

        for (Team_Provisioning__mdt rec : config.values()) {
            String team = rec.MasterLabel;
            if (!licenseByProfile.containsKey(rec.Profile_Name__c)) {
                problems.add(team + ': Profile "' + rec.Profile_Name__c + '" not found.');
            } else if (String.isNotBlank(rec.User_License__c) && licenseByProfile.get(rec.Profile_Name__c) != rec.User_License__c) {
                problems.add(team + ': Profile license is "' + licenseByProfile.get(rec.Profile_Name__c)
                    + '" but User License is "' + rec.User_License__c + '".');
            }
            if (String.isNotBlank(rec.Role_Developer_Name__c) && !foundRoles.contains(rec.Role_Developer_Name__c)) {
                problems.add(team + ': Role "' + rec.Role_Developer_Name__c + '" not found.');
            }
            for (String n : TeamProvisioningService.splitList(rec.Permission_Sets__c)) {
                if (!foundPs.contains(n)) {
                    problems.add(team + ': Permission set "' + n + '" not found.');
                }
            }
            for (String n : TeamProvisioningService.splitList(rec.Permission_Set_Groups__c)) {
                if (!foundGroups.contains(n)) {
                    problems.add(team + ': Permission set group "' + n + '" not found.');
                }
            }
        }

        System.assert(problems.isEmpty(), 'Team Provisioning configuration problems:\n' + String.join(problems, '\n'));
    }
}
