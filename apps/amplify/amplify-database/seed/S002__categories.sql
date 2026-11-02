-- Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
--
-- WSO2 LLC. licenses this file to you under the Apache License,
-- Version 2.0 (the "License"); you may not use this file except
-- in compliance with the License.
-- You may obtain a copy of the License at
--
-- http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing,
-- software distributed under the License is distributed on an
-- "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
-- KIND, either express or implied.  See the License for the
-- specific language governing permissions and limitations
-- under the License.

-- S002: campaign categories. Placeholder list until Marketing confirms it; deactivate rather than delete.

SET LOCAL ROLE amplify_migrate;

INSERT INTO campaign.category (code, label, active, sort_order)
VALUES ('PRODUCT', 'Product', true, 10),
       ('COMPANY_NEWS', 'Company news', true, 20),
       ('CUSTOMER_STORY', 'Customer story', true, 30),
       ('EVENT', 'Event', true, 40),
       ('THOUGHT_LEADERSHIP', 'Thought leadership', true, 50),
       ('CAREERS', 'Careers', true, 60)
ON CONFLICT (code) DO NOTHING;
