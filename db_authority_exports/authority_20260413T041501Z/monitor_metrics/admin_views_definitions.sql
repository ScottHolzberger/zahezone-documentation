Pager usage is off.
                              View "admin.v_customers"
      Column      |  Type  | Collation | Nullable | Default | Storage  | Description 
------------------+--------+-----------+----------+---------+----------+-------------
 halo_customer_id | bigint |           |          |         | plain    | 
 display_name     | text   |           |          |         | extended | 
 pbx_count        | bigint |           |          |         | plain    | 
 trunk_count      | bigint |           |          |         | plain    | 
View definition:
 SELECT c.halo_customer_id,
    c.display_name,
    count(DISTINCT m_pbx.module_id) AS pbx_count,
    count(DISTINCT m_trk.module_id) AS trunk_count
   FROM manage_cfg.customers c
     LEFT JOIN manage_cfg.modules m_pbx ON m_pbx.halo_customer_id = c.halo_customer_id AND m_pbx.module_type = 'PBX'::text AND m_pbx.enabled = true
     LEFT JOIN manage_cfg.modules m_trk ON m_trk.halo_customer_id = c.halo_customer_id AND m_trk.module_type = 'TRUNK'::text AND m_trk.enabled = true
  WHERE c.status = 'active'::text AND c.halo_billing_id IS NOT NULL
  GROUP BY c.halo_customer_id, c.display_name
  ORDER BY c.display_name;

                            View "admin.v_customers_all"
      Column      |  Type  | Collation | Nullable | Default | Storage  | Description 
------------------+--------+-----------+----------+---------+----------+-------------
 halo_customer_id | bigint |           |          |         | plain    | 
 halo_billing_id  | bigint |           |          |         | plain    | 
 customer_slug    | text   |           |          |         | extended | 
 display_name     | text   |           |          |         | extended | 
 status           | text   |           |          |         | extended | 
 total_services   | bigint |           |          |         | plain    | 
 lifecycle_state  | text   |           |          |         | extended | 
View definition:
 SELECT c.halo_customer_id,
    c.halo_billing_id,
    c.customer_slug,
    c.display_name,
    c.status,
    count(DISTINCT m.module_id) AS total_services,
        CASE
            WHEN c.halo_customer_id < 0 THEN 'ARCHIVED'::text
            ELSE 'ACTIVE'::text
        END AS lifecycle_state
   FROM manage_cfg.customers c
     LEFT JOIN manage_cfg.modules m ON m.halo_customer_id = c.halo_customer_id
  GROUP BY c.halo_customer_id, c.halo_billing_id, c.customer_slug, c.display_name, c.status
  ORDER BY (
        CASE
            WHEN c.halo_customer_id < 0 THEN 'ARCHIVED'::text
            ELSE 'ACTIVE'::text
        END), c.display_name;

                                View "admin.v_pbx"
    Column     |  Type   | Collation | Nullable | Default | Storage  | Description 
---------------+---------+-----------+----------+---------+----------+-------------
 module_id     | uuid    |           |          |         | plain    | 
 customer_name | text    |           |          |         | extended | 
 pbx_fqdn      | text    |           |          |         | extended | 
 enabled       | boolean |           |          |         | plain    | 
View definition:
 SELECT m.module_id,
    c.display_name AS customer_name,
    m.external_key AS pbx_fqdn,
    m.enabled
   FROM manage_cfg.modules m
     JOIN manage_cfg.customers c ON c.halo_customer_id = m.halo_customer_id
  WHERE m.module_type = 'PBX'::text AND m.enabled = true
  ORDER BY c.display_name, m.external_key;

                                 View "admin.v_trunks"
       Column       |  Type   | Collation | Nullable | Default | Storage  | Description 
--------------------+---------+-----------+----------+---------+----------+-------------
 module_id          | uuid    |           |          |         | plain    | 
 customer_name      | text    |           |          |         | extended | 
 trunk_id           | text    |           |          |         | extended | 
 provider           | text    |           |          |         | extended | 
 concurrency_cap    | integer |           |          |         | plain    | 
 monitoring_enabled | boolean |           |          |         | plain    | 
 enabled            | boolean |           |          |         | plain    | 
View definition:
 SELECT m.module_id,
    c.display_name AS customer_name,
    m.external_key AS trunk_id,
    tm.provider,
    tm.concurrency_cap,
    tm.monitoring_enabled,
    m.enabled
   FROM manage_cfg.modules m
     JOIN manage_cfg.trunk_modules tm ON tm.module_id = m.module_id
     JOIN manage_cfg.customers c ON c.halo_customer_id = m.halo_customer_id
  WHERE m.module_type = 'TRUNK'::text AND m.enabled = true
  ORDER BY c.display_name, m.external_key;

