// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

// Group-based access. Each capability is granted to a configured list of Asgardeo groups; a caller holding
// any one of them has it. No group name is fixed in code: the lists come from configuration (config.bal).

# What a matrix row requires. `EMPLOYEE` is every signed-in employee; the others come from groups.
public enum Access {
    # Every signed-in employee
    EMPLOYEE,
    # Register, edit and archive campaigns; see campaigns in any status
    CAN_CAMPAIGN,
    # The Dashboarding boards and the person popup (ADR-036)
    CAN_DASHBOARD,
    # The raw CSV export behind the boards (names and emails)
    CAN_EXPORT,
    # The external-share review queue
    CAN_REVIEW_SHARES,
    # Point rules
    CAN_POINT_RULES,
    # Adjust and reverse points; see anyone's team list and full history
    CAN_ADJUST_POINTS,
    # The PO dashboard
    CAN_PO_DASHBOARD,
    # SLT reports (phase 2)
    CAN_REPORTS,
    # Settings, kill switches, scheduler sync, failed announcements
    CAN_ADMIN
}

# Asgardeo groups granted each capability. Empty means nobody holds it.
public type AccessGroups record {|
    # Groups granted `CAN_CAMPAIGN`
    string[] canCampaign = [];
    # Groups granted `CAN_DASHBOARD`
    string[] canDashboard = [];
    # Groups granted `CAN_EXPORT`
    string[] canExport = [];
    # Groups granted `CAN_REVIEW_SHARES`
    string[] canReviewShares = [];
    # Groups granted `CAN_POINT_RULES`
    string[] canPointRules = [];
    # Groups granted `CAN_ADJUST_POINTS`
    string[] canAdjustPoints = [];
    # Groups granted `CAN_PO_DASHBOARD`
    string[] canPoDashboard = [];
    # Groups granted `CAN_REPORTS`
    string[] canReports = [];
    # Groups granted `CAN_ADMIN`
    string[] canAdmin = [];
|};

# Splits a comma (or space) separated group list from configuration.
#
# + value - Configured value, for example `amplify_po, amplify_marketing`
# + return - Trimmed group names, blanks dropped
public isolated function groupList(string value) returns string[] & readonly =>
    (from string g in re `[,\s]+`.split(value) where g.trim().length() > 0 select g.trim()).cloneReadOnly();

# Capability → groups, in `Access` order.
#
# + access - Configured groups
# + return - One pair per capability
isolated function grantTable(AccessGroups access) returns [Access, string[]][] => [
    [CAN_CAMPAIGN, access.canCampaign],
    [CAN_DASHBOARD, access.canDashboard],
    [CAN_EXPORT, access.canExport],
    [CAN_REVIEW_SHARES, access.canReviewShares],
    [CAN_POINT_RULES, access.canPointRules],
    [CAN_ADJUST_POINTS, access.canAdjustPoints],
    [CAN_PO_DASHBOARD, access.canPoDashboard],
    [CAN_REPORTS, access.canReports],
    [CAN_ADMIN, access.canAdmin]
];

# Whether the caller holds any group in a list. A blank entry never matches (fail closed).
#
# + groups - Groups that grant something
# + callerGroups - The caller's groups
# + return - True on any match
public isolated function hasAny(string[] groups, string[] callerGroups) returns boolean {
    foreach string g in groups {
        string name = g.trim();
        if name.length() > 0 && callerGroups.indexOf(name) !is () {
            return true;
        }
    }
    return false;
}

# The caller's grants. Everyone has `EMPLOYEE`; each capability whose groups the caller holds is added.
#
# + callerGroups - The caller's groups
# + access - Configured groups
# + return - Grants, in `Access` order
public isolated function grantsOf(string[] callerGroups, AccessGroups access) returns Access[] {
    Access[] result = [EMPLOYEE];
    foreach [Access, string[]] [grant, groups] in grantTable(access) {
        if hasAny(groups, callerGroups) {
            result.push(grant);
        }
    }
    return result;
}

# Every group named anywhere in the configuration, once each.
#
# + access - Configured groups
# + return - Distinct group names
public isolated function configuredGroups(AccessGroups access) returns string[] {
    string[] result = [];
    foreach [Access, string[]] [_, groups] in grantTable(access) {
        foreach string g in groups {
            string name = g.trim();
            if name.length() > 0 && result.indexOf(name) is () {
                result.push(name);
            }
        }
    }
    return result;
}
