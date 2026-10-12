/**
 * Unit tests for team-based provisioning. Config is injected in memory, so these tests do
 * not depend on the org's Team_Provisioning__mdt records. TeamProvisioningConfigTest checks
 * the real records.
 */
@IsTest
private class TeamProvisioningTest {

    private static final String PROFILE_NAME = 'Standard User';

    /** First active Team__c value, so inserted test users always pass the restricted picklist. */
    private static String teamKey() {
        for (Schema.PicklistEntry e : User.Team__c.getDescribe().getPicklistValues()) {
            if (e.isActive()) {
                return e.getValue();
            }
        }
        System.assert(false, 'User.Team__c needs at least one active value.');
        return null;
    }

    private static Team_Provisioning__mdt config(String label, Boolean active, String license, String role,
                                                 String permSets, String groups, Boolean flags) {
        Map<String, Object> m = new Map<String, Object>{
            'MasterLabel' => label,
            'DeveloperName' => label,
            'Active__c' => active,
            'Profile_Name__c' => PROFILE_NAME,
            'User_License__c' => license,
            'Role_Developer_Name__c' => role,
            'Permission_Sets__c' => permSets,
            'Permission_Set_Groups__c' => groups,
            'Marketing_User__c' => flags,
            'Knowledge_User__c' => false,
            'Service_Cloud_User__c' => false
        };
        return (Team_Provisioning__mdt) JSON.deserialize(JSON.serialize(m), Team_Provisioning__mdt.class);
    }

    private static void useConfig(Team_Provisioning__mdt rec) {
        TeamProvisioningService.configCache = new Map<String, Team_Provisioning__mdt>{ rec.MasterLabel => rec };
    }

    private static Profile standardProfile() {
        return [SELECT Id, UserLicense.Name FROM Profile WHERE Name = :PROFILE_NAME LIMIT 1];
    }

    private static User newUser(String suffix) {
        String unique = suffix + DateTime.now().getTime() + Crypto.getRandomInteger();
        return new User(
            ProfileId = standardProfile().Id,
            LastName = 'TeamProv' + suffix,
            Email = 'teamprov' + suffix + '@example.com',
            Username = 'teamprov.' + unique + '@example.com.test',
            Alias = 'tp' + suffix.left(6),
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }

    private static PermissionSet newPermSet(String name) {
        PermissionSet ps = new PermissionSet(Name = name, Label = name);
        insert ps;
        return ps;
    }

    private static Set<Id> assignedPermSetIds(Id userId) {
        Set<Id> ids = new Set<Id>();
        for (PermissionSetAssignment psa : [
            SELECT PermissionSetId FROM PermissionSetAssignment
            WHERE AssigneeId = :userId AND PermissionSet.IsOwnedByProfile = false
        ]) {
            ids.add(psa.PermissionSetId);
        }
        return ids;
    }

    // ------------------------------------------------------------------ Phase 1

    @IsTest
    static void applyUserFields_setsProfileRoleAndFlags() {
        UserRole role = new UserRole(Name = 'TP Test Role', DeveloperName = 'TP_Test_Role');
        insert role;
        String license = standardProfile().UserLicense.Name;
        useConfig(config('Team_A', true, license, 'TP_Test_Role', null, null, true));

        User u = newUser('a');
        u.Team__c = 'Team_A';
        Map<Integer, String> errors = TeamProvisioningService.applyUserFields(new List<User>{ u });

        System.assert(errors.isEmpty(), String.valueOf(errors));
        System.assertEquals(standardProfile().Id, u.ProfileId);
        System.assertEquals(role.Id, u.UserRoleId);
        System.assertEquals(true, u.UserPermissionsMarketingUser);
        System.assertEquals(TeamProvisioningService.STATUS_PENDING, u.Provisioning_Status__c);
    }

    @IsTest
    static void applyUserFields_blankRoleClearsRole() {
        useConfig(config('Team_A', true, standardProfile().UserLicense.Name, null, null, null, false));
        User u = newUser('b');
        u.Team__c = 'Team_A';
        u.UserRoleId = null;
        TeamProvisioningService.applyUserFields(new List<User>{ u });
        System.assertEquals(null, u.UserRoleId);
    }

    @IsTest
    static void applyUserFields_licenseMismatchIsError() {
        String license = standardProfile().UserLicense.Name;
        String other = license == 'Salesforce' ? 'Salesforce Platform' : 'Salesforce';
        useConfig(config('Team_A', true, other, null, null, null, false));
        User u = newUser('c');
        u.Team__c = 'Team_A';
        Map<Integer, String> errors = TeamProvisioningService.applyUserFields(new List<User>{ u });
        System.assert(errors.get(0).contains('license'), String.valueOf(errors));
    }

    @IsTest
    static void applyUserFields_missingAndInactiveConfigAreErrors() {
        useConfig(config('Team_A', false, standardProfile().UserLicense.Name, null, null, null, false));
        User inactive = newUser('d');
        inactive.Team__c = 'Team_A';
        User missing = newUser('e');
        missing.Team__c = 'No_Such_Team';
        Map<Integer, String> errors = TeamProvisioningService.applyUserFields(new List<User>{ inactive, missing });
        System.assert(errors.get(0).contains('inactive'));
        System.assert(errors.get(1).contains('No Team Provisioning record'));
    }

    @IsTest
    static void applyUserFields_blankTeamKeepsProfileAndRoleClearsFlags() {
        useConfig(config('Team_A', true, standardProfile().UserLicense.Name, null, null, null, true));
        User u = newUser('f');
        Id originalProfile = u.ProfileId;
        u.UserPermissionsMarketingUser = true;
        u.Team__c = null;
        TeamProvisioningService.applyUserFields(new List<User>{ u });
        System.assertEquals(originalProfile, u.ProfileId);
        System.assertEquals(false, u.UserPermissionsMarketingUser);
    }

    @IsTest
    static void handler_beforeInsertAndBeforeUpdateApplyOnlyOnChange() {
        useConfig(config('Team_A', true, standardProfile().UserLicense.Name, null, null, null, true));
        User u = newUser('g');
        u.Team__c = 'Team_A';
        TeamProvisioningHandler.beforeInsert(new List<User>{ u });
        System.assertEquals(true, u.UserPermissionsMarketingUser);

        User unchanged = newUser('h');
        unchanged.Team__c = 'Team_A';
        unchanged.UserPermissionsMarketingUser = false;
        // Same Team in old and new: handler must not touch the record.
        TeamProvisioningHandler.beforeUpdate(new List<User>{ unchanged }, new Map<Id, User>{ null => unchanged.clone() });
        System.assertEquals(false, unchanged.UserPermissionsMarketingUser);
    }

    // ------------------------------------------------------------------ Phase 2

    @IsTest
    static void sync_fullOverwriteRemovesOldAndAddsNew() {
        PermissionSet oldPs = newPermSet('TP_Old_Test');
        PermissionSet newPs = newPermSet('TP_New_Test');
        User u = newUser('i');
        insert u;
        insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = oldPs.Id);
        useConfig(config('Team_A', true, standardProfile().UserLicense.Name, null, 'TP_New_Test', null, false));

        Test.startTest();
        TeamProvisioningService.syncAndRecord(new Map<Id, String>{ u.Id => 'Team_A' });
        Test.stopTest();

        Set<Id> assigned = assignedPermSetIds(u.Id);
        System.assert(assigned.contains(newPs.Id), 'New permission set should be assigned');
        System.assert(!assigned.contains(oldPs.Id), 'Old permission set should be removed');
        User after = [SELECT Provisioning_Status__c FROM User WHERE Id = :u.Id];
        System.assertEquals(TeamProvisioningService.STATUS_SUCCESS, after.Provisioning_Status__c);
    }

    @IsTest
    static void sync_blankTeamRemovesAllNonProfileAssignments() {
        PermissionSet ps = newPermSet('TP_Clear_Test');
        User u = newUser('j');
        insert u;
        insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        useConfig(config('Team_A', true, standardProfile().UserLicense.Name, null, null, null, false));

        Test.startTest();
        TeamProvisioningService.syncAndRecord(new Map<Id, String>{ u.Id => null });
        Test.stopTest();

        System.assert(!assignedPermSetIds(u.Id).contains(ps.Id));
    }

    @IsTest
    static void sync_unknownNamesAreReportedAsErrors() {
        User u = newUser('k');
        insert u;
        useConfig(config('Team_A', true, standardProfile().UserLicense.Name, null, 'Does_Not_Exist', 'No_Group', false));

        Test.startTest();
        TeamProvisioningService.syncAndRecord(new Map<Id, String>{ u.Id => 'Team_A' });
        Test.stopTest();

        User after = [SELECT Provisioning_Status__c, Provisioning_Message__c FROM User WHERE Id = :u.Id];
        System.assertEquals(TeamProvisioningService.STATUS_ERROR, after.Provisioning_Status__c);
        System.assert(after.Provisioning_Message__c.contains('Does_Not_Exist'));
        System.assert(after.Provisioning_Message__c.contains('No_Group'));
    }

    @IsTest
    static void sync_missingConfigDoesNotStripAccess() {
        PermissionSet ps = newPermSet('TP_Keep_Test');
        User u = newUser('l');
        insert u;
        insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        TeamProvisioningService.configCache = new Map<String, Team_Provisioning__mdt>();

        Test.startTest();
        TeamProvisioningService.syncAndRecord(new Map<Id, String>{ u.Id => 'Unknown_Team' });
        Test.stopTest();

        System.assert(assignedPermSetIds(u.Id).contains(ps.Id));
    }

    @IsTest
    static void queueable_runsSync() {
        PermissionSet ps = newPermSet('TP_Queue_Test');
        String key = teamKey();
        useConfig(config(key, true, standardProfile().UserLicense.Name, null, 'TP_Queue_Test', null, false));
        User u = newUser('m');
        insert u;
        u.Team__c = key;
        update u;

        Test.startTest();
        TeamProvisioningService.enqueueSync(new Set<Id>{ u.Id });
        Test.stopTest();

        System.assert(assignedPermSetIds(u.Id).contains(ps.Id));
    }

    @IsTest
    static void resyncBatch_appliesFieldsAndAssignments() {
        PermissionSet ps = newPermSet('TP_Batch_Test');
        String key = teamKey();
        useConfig(config(key, true, standardProfile().UserLicense.Name, null, 'TP_Batch_Test', null, false));
        User u = newUser('n');
        u.Team__c = key;
        insert u;

        Test.startTest();
        TeamProvisioningResyncBatch.resync(new List<String>{ key });
        Test.stopTest();

        // Feature licenses stay false here so the test does not depend on available Marketing User seats.
        User after = [SELECT Provisioning_Status__c FROM User WHERE Id = :u.Id];
        System.assertEquals(TeamProvisioningService.STATUS_SUCCESS, after.Provisioning_Status__c);
        System.assert(assignedPermSetIds(u.Id).contains(ps.Id));
    }

    // ------------------------------------------------------------------ Helpers

    @IsTest
    static void helpers_parseNames() {
        Set<String> parsed = TeamProvisioningService.splitList(' A , B;C\nD ,, ');
        System.assertEquals(new Set<String>{ 'A', 'B', 'C', 'D' }, parsed);
        System.assertEquals('Name', TeamProvisioningService.bareName('ns__Name'));
        System.assertEquals('Name', TeamProvisioningService.bareName('Name'));
        System.assertEquals('ns__Name', TeamProvisioningService.qualifiedName('ns', 'Name'));
        System.assertEquals('Name', TeamProvisioningService.qualifiedName(null, 'Name'));
    }
}
