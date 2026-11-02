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


// Read side of S1 for the published API (M5): paged campaign lists, tags and categories. Reads only the
// `campaign` schema; `sql:ParameterizedQuery` only (optional filters are joined with `sql:queryConcat`).

import amplify_domain.store;

import ballerina/sql;
import ballerina/time;
import ballerinax/postgresql;

# Largest page the API serves.
public const int MAX_PAGE_SIZE = 50;

# Filters for a campaign list.
public type CampaignQuery record {|
    # Derived statuses to include; empty = any
    CampaignStatus[] statuses = [];
    # Only campaigns that opened in the last N days; `()` = no limit
    int? windowDays = ();
    # Only campaigns with this (lowercase) tag
    string? tag = ();
    # Zero-based page
    int page = 0;
    # Page size, 1..MAX_PAGE_SIZE
    int size = 14;
|};

# One page of campaigns.
public type CampaignPage record {|
    # Campaigns, priority first, newest first
    Campaign[] items;
    # Matching rows across all pages
    int total;
|};

# A campaign category (`campaign.category`).
public type Category record {|
    # Code, for example `PRODUCT`
    string code;
    # Label shown in the UI
    string label;
    # Order in pickers
    int sortOrder;
|};

type ListedRow record {|
    string id;
    string provider;
    string resource_urn;
    string resource_type;
    string owner_urn;
    string? resource_url;
    string title;
    string? summary;
    string? image_url;
    string category_code;
    boolean is_priority;
    time:Utc opens_at;
    time:Utc closes_at;
    time:Utc? archived_at;
    string created_by;
    time:Utc created_at;
    time:Utc updated_at;
    int version;
    string tags;
    int total;
|};

# Lists campaigns, priority first, then newest `opens_at`.
#
# + db - Client
# + query - Filters and paging
# + now - Current time (window start)
# + return - The page, or an error
public isolated function listCampaigns(postgresql:Client db, CampaignQuery query, time:Utc now)
        returns CampaignPage|error {
    sql:ParameterizedQuery cond = `WHERE TRUE`;
    if query.statuses.length() > 0 {
        string statuses = store:arrayLiteral(query.statuses);
        cond = sql:queryConcat(cond, ` AND c.status = ANY (CAST(${statuses} AS text[]))`);
    }
    int? windowDays = query.windowDays;
    if windowDays is int {
        string since = time:utcToString(time:utcAddSeconds(now, -86400d * <decimal>windowDays));
        cond = sql:queryConcat(cond, ` AND c.opens_at >= CAST(${since} AS timestamptz)`);
    }
    string? tag = query.tag;
    if tag is string {
        cond = sql:queryConcat(cond, ` AND EXISTS (SELECT 1 FROM campaign.campaign_tag t
                                                     WHERE t.campaign_id = c.id AND t.tag = ${tag})`);
    }
    [int, int] [size, offset] = store:pageWindow(query.page, query.size, MAX_PAGE_SIZE);
    sql:ParameterizedQuery sqlQuery = sql:queryConcat(`
        SELECT c.id::text AS id, c.provider, c.resource_urn, c.resource_type, c.owner_urn, c.resource_url, c.title,
               c.summary, c.image_url, c.category_code, c.is_priority, c.opens_at, c.closes_at, c.archived_at,
               c.created_by, c.created_at, c.updated_at, c.version,
               COALESCE((SELECT array_to_json(array_agg(t.tag ORDER BY t.tag))::text
                         FROM campaign.campaign_tag t WHERE t.campaign_id = c.id), '[]') AS tags,
               (count(*) OVER ())::int AS total
        FROM campaign.campaign_v c `, cond, `
        ORDER BY c.is_priority DESC, c.opens_at DESC, c.id
        LIMIT ${size} OFFSET ${offset}`);
    stream<ListedRow, error?> rows = db->query(sqlQuery);
    int total = 0;
    Campaign[] items = [];
    check from ListedRow r in rows
        do {
            total = r.total;
            items.push({
                id: r.id,
                provider: check r.provider.ensureType(),
                resourceUrn: r.resource_urn,
                resourceType: check r.resource_type.ensureType(),
                ownerUrn: r.owner_urn,
                resourceUrl: r.resource_url,
                title: r.title,
                summary: r.summary,
                imageUrl: r.image_url,
                categoryCode: r.category_code,
                isPriority: r.is_priority,
                tags: check r.tags.fromJsonStringWithType(),
                opensAt: r.opens_at,
                closesAt: r.closes_at,
                archivedAt: r.archived_at,
                createdBy: r.created_by,
                createdAt: r.created_at,
                updatedAt: r.updated_at,
                version: r.version
            });
        };
    if items.length() == 0 && offset > 0 {
        int|error counted = db->queryRow(sql:queryConcat(`SELECT count(*)::int FROM campaign.campaign_v c `, cond));
        total = counted is int ? counted : 0;
    }
    return {items, total};
}

# Tags in use on campaigns that aren't archived, alphabetical.
#
# + db - Client
# + return - Tags, or an error
public isolated function listTags(postgresql:Client db) returns string[]|error {
    stream<record {|string tag;|}, error?> rows = db->query(`
        SELECT DISTINCT t.tag FROM campaign.campaign_tag t
        JOIN campaign.campaign c ON c.id = t.campaign_id
        WHERE c.archived_at IS NULL
        ORDER BY t.tag`);
    return from var r in rows
        select r.tag;
}

# Active categories in picker order.
#
# + db - Client
# + return - Categories, or an error
public isolated function listCategories(postgresql:Client db) returns Category[]|error {
    stream<record {|string code; string label; int sort_order;|}, error?> rows = db->query(`
        SELECT code, label, sort_order FROM campaign.category WHERE active ORDER BY sort_order, label`);
    return from var r in rows
        select {code: r.code, label: r.label, sortOrder: r.sort_order};
}

# Campaigns for the PO dashboard: open, or closed in the last `recentDays` (not archived), priority
# first then newest, at most `limit`.
#
# + db - Client
# + recentDays - Look-back for closed campaigns
# + limit - Most rows
# + now - Current time
# + return - Campaigns, or an error
public isolated function dashboardCampaigns(postgresql:Client db, int recentDays, int 'limit, time:Utc now)
        returns Campaign[]|error {
    string since = time:utcToString(time:utcAddSeconds(now, -86400d * <decimal>recentDays));
    stream<ListedRow, error?> rows = db->query(`
        SELECT c.id::text AS id, c.provider, c.resource_urn, c.resource_type, c.owner_urn, c.resource_url, c.title,
               c.summary, c.image_url, c.category_code, c.is_priority, c.opens_at, c.closes_at, c.archived_at,
               c.created_by, c.created_at, c.updated_at, c.version, '[]' AS tags, 0 AS total
        FROM campaign.campaign_v c
        WHERE c.status = 'OPEN' OR (c.status = 'CLOSED' AND c.closes_at >= CAST(${since} AS timestamptz))
        ORDER BY c.is_priority DESC, c.opens_at DESC, c.id
        LIMIT ${'limit}`);
    return from ListedRow r in rows
        select {
            id: r.id,
            provider: check r.provider.ensureType(),
            resourceUrn: r.resource_urn,
            resourceType: check r.resource_type.ensureType(),
            ownerUrn: r.owner_urn,
            resourceUrl: r.resource_url,
            title: r.title,
            summary: r.summary,
            imageUrl: r.image_url,
            categoryCode: r.category_code,
            isPriority: r.is_priority,
            tags: [],
            opensAt: r.opens_at,
            closesAt: r.closes_at,
            archivedAt: r.archived_at,
            createdBy: r.created_by,
            createdAt: r.created_at,
            updatedAt: r.updated_at,
            version: r.version
        };
}
