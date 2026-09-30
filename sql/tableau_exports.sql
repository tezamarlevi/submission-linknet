-- T01 -> portfolio_month.csv
WITH
    lk_homepass AS (
        SELECT
            h.homeid,
            h.region,
            h.fibernode,
            r.island,
            r.urban_rural,
            h.technology,
            h.build_date::timestamp::date AS build_date,
            h.capex_cost::numeric AS capex_cost,
            h.exclusive_flag,
            h.exclusive_servco_id,
            NULLIF(BTRIM(h.exclusive_start_date), '')::date AS exclusive_start_date,
            NULLIF(BTRIM(h.exclusive_end_date), '')::date AS exclusive_end_date,
            CASE WHEN h.exclusive_flag = 'Y' THEN 'EVER_EXCLUSIVE'
                 ELSE 'NEVER_EXCLUSIVE' END AS exclusive_cohort
        FROM linknet_assesment.homepass_fin AS h
        LEFT JOIN linknet_assesment.region_master_fin AS r
               ON r.fibernode = h.fibernode
    ),
    lk_months AS (
        SELECT DISTINCT snapshot_date::timestamp::date AS month_end
        FROM linknet_assesment.subscription_snapshot_fin
    ),
    lk_asset_month AS (
        SELECT
            m.month_end,
            h.*,
            (o.homeid IS NOT NULL) AS snapshot_observed,
            CASE
                WHEN h.exclusive_flag <> 'Y' THEN 'NEVER_EXCLUSIVE'
                WHEN m.month_end < h.exclusive_start_date THEN 'PRE_EXCLUSIVE'
                WHEN m.month_end <= h.exclusive_end_date THEN 'EXCLUSIVE_WINDOW'
                ELSE 'POST_EXCLUSIVE'
            END AS access_period
        FROM lk_months AS m
        CROSS JOIN lk_homepass AS h
        LEFT JOIN (
            SELECT DISTINCT snapshot_date::timestamp::date AS month_end, homeid
            FROM linknet_assesment.subscription_snapshot_fin
        ) AS o ON o.month_end = m.month_end AND o.homeid = h.homeid
    ),
    lk_active_ca AS (
        SELECT
            a.month_end,
            s.homeid,
            s.servco_id,
            s.contract_account,
            s.bandwidth_mbps,
            a.region,
            a.fibernode,
            a.urban_rural,
            a.technology,
            a.exclusive_cohort,
            a.access_period,
            v.servco_name,
            v.lease_fee_per_active::numeric AS lease_proxy,
            (m.contract_account IS NOT NULL) AS media_attached,
            m.catv_package,
            m.add_on_product,
            m.package_price,
            m.ao_wholesale_price,
            m.ao_rrp_price,
            CASE WHEN m.contract_account IS NULL THEN 0::numeric
                 ELSE (m.package_price + m.ao_rrp_price)::numeric
            END AS media_gross_proxy,
            CASE WHEN m.contract_account IS NULL THEN 0::numeric
                 ELSE (m.ao_rrp_price - m.ao_wholesale_price)::numeric
            END AS addon_margin_proxy
        FROM linknet_assesment.subscription_snapshot_fin AS s
        JOIN lk_asset_month AS a
          ON a.month_end = s.snapshot_date::timestamp::date AND a.homeid = s.homeid
        JOIN linknet_assesment.servco_fin AS v ON v.servco_id = s.servco_id
        LEFT JOIN linknet_assesment.media_package_fin AS m
               ON m.contract_account = s.contract_account
        WHERE s.status = 'ACTIVE'
          AND s.active_flag = 1
          AND NULLIF(BTRIM(s.contract_account), '') IS NOT NULL
    ),
    lk_month_home AS (
        WITH service AS (
            SELECT
                month_end,
                homeid,
                COUNT(DISTINCT contract_account) AS active_ca_count,
                COUNT(DISTINCT servco_id) AS active_servco_count,
                COUNT(DISTINCT contract_account) FILTER (WHERE servco_id = 101)
                    AS xls_active_ca_count,
                COUNT(DISTINCT contract_account) FILTER (WHERE servco_id <> 101)
                    AS other_active_ca_count,
                SUM(lease_proxy) AS lease_proxy,
                COUNT(DISTINCT contract_account) FILTER (WHERE media_attached)
                    AS media_attached_ca_count,
                SUM(media_gross_proxy) AS media_gross_proxy,
                SUM(addon_margin_proxy) AS addon_margin_proxy
            FROM lk_active_ca
            GROUP BY month_end, homeid
        )
        SELECT
            a.month_end,
            a.homeid,
            a.region,
            a.fibernode,
            a.island,
            a.urban_rural,
            a.technology,
            a.build_date,
            a.capex_cost,
            a.exclusive_flag,
            a.exclusive_servco_id,
            a.exclusive_cohort,
            a.access_period,
            a.snapshot_observed,
            COALESCE(s.active_ca_count, 0) AS active_ca_count,
            COALESCE(s.active_servco_count, 0) AS active_servco_count,
            COALESCE(s.xls_active_ca_count, 0) AS xls_active_ca_count,
            COALESCE(s.other_active_ca_count, 0) AS other_active_ca_count,
            COALESCE(s.lease_proxy, 0) AS lease_proxy,
            COALESCE(s.media_attached_ca_count, 0) AS media_attached_ca_count,
            COALESCE(s.media_gross_proxy, 0) AS media_gross_proxy,
            COALESCE(s.addon_margin_proxy, 0) AS addon_margin_proxy
        FROM lk_asset_month AS a
        LEFT JOIN service AS s
               ON s.month_end = a.month_end AND s.homeid = a.homeid
    )
SELECT
    month_end,
    COUNT(*) AS homepasses,
    COUNT(*) FILTER (WHERE snapshot_observed) AS observed_homepasses,
    SUM(active_ca_count) AS active_ca,
    COUNT(*) FILTER (WHERE active_ca_count > 0) AS occupied_homepasses,
    ROUND(100.0 * SUM(active_ca_count) / NULLIF(COUNT(*), 0), 2) AS ca_penetration_pct,
    SUM(capex_cost) AS capex_total,
    SUM(lease_proxy) AS lease_proxy,
    ROUND(SUM(lease_proxy) / NULLIF(COUNT(*), 0), 0) AS lease_per_homepass_proxy,
    SUM(media_attached_ca_count) AS media_attached_ca,
    ROUND(100.0 * SUM(media_attached_ca_count) / NULLIF(SUM(active_ca_count), 0), 2) AS media_attach_pct,
    SUM(media_gross_proxy) AS media_gross_proxy,
    SUM(addon_margin_proxy) AS addon_margin_proxy
FROM lk_month_home
GROUP BY month_end
ORDER BY month_end;

-- T02 -> segment_month.csv
WITH
    lk_homepass AS (
        SELECT
            h.homeid,
            h.region,
            h.fibernode,
            r.island,
            r.urban_rural,
            h.technology,
            h.build_date::timestamp::date AS build_date,
            h.capex_cost::numeric AS capex_cost,
            h.exclusive_flag,
            h.exclusive_servco_id,
            NULLIF(BTRIM(h.exclusive_start_date), '')::date AS exclusive_start_date,
            NULLIF(BTRIM(h.exclusive_end_date), '')::date AS exclusive_end_date,
            CASE WHEN h.exclusive_flag = 'Y' THEN 'EVER_EXCLUSIVE'
                 ELSE 'NEVER_EXCLUSIVE' END AS exclusive_cohort
        FROM linknet_assesment.homepass_fin AS h
        LEFT JOIN linknet_assesment.region_master_fin AS r
               ON r.fibernode = h.fibernode
    ),
    lk_months AS (
        SELECT DISTINCT snapshot_date::timestamp::date AS month_end
        FROM linknet_assesment.subscription_snapshot_fin
    ),
    lk_asset_month AS (
        SELECT
            m.month_end,
            h.*,
            (o.homeid IS NOT NULL) AS snapshot_observed,
            CASE
                WHEN h.exclusive_flag <> 'Y' THEN 'NEVER_EXCLUSIVE'
                WHEN m.month_end < h.exclusive_start_date THEN 'PRE_EXCLUSIVE'
                WHEN m.month_end <= h.exclusive_end_date THEN 'EXCLUSIVE_WINDOW'
                ELSE 'POST_EXCLUSIVE'
            END AS access_period
        FROM lk_months AS m
        CROSS JOIN lk_homepass AS h
        LEFT JOIN (
            SELECT DISTINCT snapshot_date::timestamp::date AS month_end, homeid
            FROM linknet_assesment.subscription_snapshot_fin
        ) AS o ON o.month_end = m.month_end AND o.homeid = h.homeid
    ),
    lk_active_ca AS (
        SELECT
            a.month_end,
            s.homeid,
            s.servco_id,
            s.contract_account,
            s.bandwidth_mbps,
            a.region,
            a.fibernode,
            a.urban_rural,
            a.technology,
            a.exclusive_cohort,
            a.access_period,
            v.servco_name,
            v.lease_fee_per_active::numeric AS lease_proxy,
            (m.contract_account IS NOT NULL) AS media_attached,
            m.catv_package,
            m.add_on_product,
            m.package_price,
            m.ao_wholesale_price,
            m.ao_rrp_price,
            CASE WHEN m.contract_account IS NULL THEN 0::numeric
                 ELSE (m.package_price + m.ao_rrp_price)::numeric
            END AS media_gross_proxy,
            CASE WHEN m.contract_account IS NULL THEN 0::numeric
                 ELSE (m.ao_rrp_price - m.ao_wholesale_price)::numeric
            END AS addon_margin_proxy
        FROM linknet_assesment.subscription_snapshot_fin AS s
        JOIN lk_asset_month AS a
          ON a.month_end = s.snapshot_date::timestamp::date AND a.homeid = s.homeid
        JOIN linknet_assesment.servco_fin AS v ON v.servco_id = s.servco_id
        LEFT JOIN linknet_assesment.media_package_fin AS m
               ON m.contract_account = s.contract_account
        WHERE s.status = 'ACTIVE'
          AND s.active_flag = 1
          AND NULLIF(BTRIM(s.contract_account), '') IS NOT NULL
    ),
    lk_month_home AS (
        WITH service AS (
            SELECT
                month_end,
                homeid,
                COUNT(DISTINCT contract_account) AS active_ca_count,
                COUNT(DISTINCT servco_id) AS active_servco_count,
                COUNT(DISTINCT contract_account) FILTER (WHERE servco_id = 101)
                    AS xls_active_ca_count,
                COUNT(DISTINCT contract_account) FILTER (WHERE servco_id <> 101)
                    AS other_active_ca_count,
                SUM(lease_proxy) AS lease_proxy,
                COUNT(DISTINCT contract_account) FILTER (WHERE media_attached)
                    AS media_attached_ca_count,
                SUM(media_gross_proxy) AS media_gross_proxy,
                SUM(addon_margin_proxy) AS addon_margin_proxy
            FROM lk_active_ca
            GROUP BY month_end, homeid
        )
        SELECT
            a.month_end,
            a.homeid,
            a.region,
            a.fibernode,
            a.island,
            a.urban_rural,
            a.technology,
            a.build_date,
            a.capex_cost,
            a.exclusive_flag,
            a.exclusive_servco_id,
            a.exclusive_cohort,
            a.access_period,
            a.snapshot_observed,
            COALESCE(s.active_ca_count, 0) AS active_ca_count,
            COALESCE(s.active_servco_count, 0) AS active_servco_count,
            COALESCE(s.xls_active_ca_count, 0) AS xls_active_ca_count,
            COALESCE(s.other_active_ca_count, 0) AS other_active_ca_count,
            COALESCE(s.lease_proxy, 0) AS lease_proxy,
            COALESCE(s.media_attached_ca_count, 0) AS media_attached_ca_count,
            COALESCE(s.media_gross_proxy, 0) AS media_gross_proxy,
            COALESCE(s.addon_margin_proxy, 0) AS addon_margin_proxy
        FROM lk_asset_month AS a
        LEFT JOIN service AS s
               ON s.month_end = a.month_end AND s.homeid = a.homeid
    )
SELECT
    h.month_end,
    d.segment_type,
    d.segment_value,
    COUNT(*) AS homepasses,
    COUNT(*) FILTER (WHERE h.snapshot_observed) AS observed_homepasses,
    SUM(h.active_ca_count) AS active_ca,
    COUNT(*) FILTER (WHERE h.active_ca_count > 0) AS occupied_homepasses,
    ROUND(100.0 * SUM(h.active_ca_count) / NULLIF(COUNT(*), 0), 2) AS ca_penetration_pct,
    SUM(h.capex_cost) AS capex_total,
    SUM(h.lease_proxy) AS lease_proxy,
    ROUND(SUM(h.lease_proxy) / NULLIF(COUNT(*), 0), 0) AS lease_per_homepass_proxy,
    SUM(h.media_attached_ca_count) AS media_attached_ca,
    ROUND(100.0 * SUM(h.media_attached_ca_count) / NULLIF(SUM(h.active_ca_count), 0), 2) AS media_attach_pct,
    SUM(h.media_gross_proxy) AS media_gross_proxy,
    SUM(h.addon_margin_proxy) AS addon_margin_proxy
FROM lk_month_home AS h
CROSS JOIN LATERAL (VALUES
    ('region', h.region),
    ('technology', h.technology),
    ('historical_exclusivity', h.exclusive_cohort),
    ('access_period', h.access_period),
    ('region_technology_cohort', CONCAT_WS(' / ', h.region, h.technology, h.exclusive_cohort))
) AS d(segment_type, segment_value)
GROUP BY h.month_end, d.segment_type, d.segment_value
ORDER BY h.month_end, d.segment_type, d.segment_value;

-- T03 -> node_month.csv
WITH
    lk_homepass AS (
        SELECT
            h.homeid,
            h.region,
            h.fibernode,
            r.island,
            r.urban_rural,
            h.technology,
            h.build_date::timestamp::date AS build_date,
            h.capex_cost::numeric AS capex_cost,
            h.exclusive_flag,
            h.exclusive_servco_id,
            NULLIF(BTRIM(h.exclusive_start_date), '')::date AS exclusive_start_date,
            NULLIF(BTRIM(h.exclusive_end_date), '')::date AS exclusive_end_date,
            CASE WHEN h.exclusive_flag = 'Y' THEN 'EVER_EXCLUSIVE'
                 ELSE 'NEVER_EXCLUSIVE' END AS exclusive_cohort
        FROM linknet_assesment.homepass_fin AS h
        LEFT JOIN linknet_assesment.region_master_fin AS r
               ON r.fibernode = h.fibernode
    ),
    lk_months AS (
        SELECT DISTINCT snapshot_date::timestamp::date AS month_end
        FROM linknet_assesment.subscription_snapshot_fin
    ),
    lk_asset_month AS (
        SELECT
            m.month_end,
            h.*,
            (o.homeid IS NOT NULL) AS snapshot_observed,
            CASE
                WHEN h.exclusive_flag <> 'Y' THEN 'NEVER_EXCLUSIVE'
                WHEN m.month_end < h.exclusive_start_date THEN 'PRE_EXCLUSIVE'
                WHEN m.month_end <= h.exclusive_end_date THEN 'EXCLUSIVE_WINDOW'
                ELSE 'POST_EXCLUSIVE'
            END AS access_period
        FROM lk_months AS m
        CROSS JOIN lk_homepass AS h
        LEFT JOIN (
            SELECT DISTINCT snapshot_date::timestamp::date AS month_end, homeid
            FROM linknet_assesment.subscription_snapshot_fin
        ) AS o ON o.month_end = m.month_end AND o.homeid = h.homeid
    ),
    lk_active_ca AS (
        SELECT
            a.month_end,
            s.homeid,
            s.servco_id,
            s.contract_account,
            s.bandwidth_mbps,
            a.region,
            a.fibernode,
            a.urban_rural,
            a.technology,
            a.exclusive_cohort,
            a.access_period,
            v.servco_name,
            v.lease_fee_per_active::numeric AS lease_proxy,
            (m.contract_account IS NOT NULL) AS media_attached,
            m.catv_package,
            m.add_on_product,
            m.package_price,
            m.ao_wholesale_price,
            m.ao_rrp_price,
            CASE WHEN m.contract_account IS NULL THEN 0::numeric
                 ELSE (m.package_price + m.ao_rrp_price)::numeric
            END AS media_gross_proxy,
            CASE WHEN m.contract_account IS NULL THEN 0::numeric
                 ELSE (m.ao_rrp_price - m.ao_wholesale_price)::numeric
            END AS addon_margin_proxy
        FROM linknet_assesment.subscription_snapshot_fin AS s
        JOIN lk_asset_month AS a
          ON a.month_end = s.snapshot_date::timestamp::date AND a.homeid = s.homeid
        JOIN linknet_assesment.servco_fin AS v ON v.servco_id = s.servco_id
        LEFT JOIN linknet_assesment.media_package_fin AS m
               ON m.contract_account = s.contract_account
        WHERE s.status = 'ACTIVE'
          AND s.active_flag = 1
          AND NULLIF(BTRIM(s.contract_account), '') IS NOT NULL
    ),
    lk_month_home AS (
        WITH service AS (
            SELECT
                month_end,
                homeid,
                COUNT(DISTINCT contract_account) AS active_ca_count,
                COUNT(DISTINCT servco_id) AS active_servco_count,
                COUNT(DISTINCT contract_account) FILTER (WHERE servco_id = 101)
                    AS xls_active_ca_count,
                COUNT(DISTINCT contract_account) FILTER (WHERE servco_id <> 101)
                    AS other_active_ca_count,
                SUM(lease_proxy) AS lease_proxy,
                COUNT(DISTINCT contract_account) FILTER (WHERE media_attached)
                    AS media_attached_ca_count,
                SUM(media_gross_proxy) AS media_gross_proxy,
                SUM(addon_margin_proxy) AS addon_margin_proxy
            FROM lk_active_ca
            GROUP BY month_end, homeid
        )
        SELECT
            a.month_end,
            a.homeid,
            a.region,
            a.fibernode,
            a.island,
            a.urban_rural,
            a.technology,
            a.build_date,
            a.capex_cost,
            a.exclusive_flag,
            a.exclusive_servco_id,
            a.exclusive_cohort,
            a.access_period,
            a.snapshot_observed,
            COALESCE(s.active_ca_count, 0) AS active_ca_count,
            COALESCE(s.active_servco_count, 0) AS active_servco_count,
            COALESCE(s.xls_active_ca_count, 0) AS xls_active_ca_count,
            COALESCE(s.other_active_ca_count, 0) AS other_active_ca_count,
            COALESCE(s.lease_proxy, 0) AS lease_proxy,
            COALESCE(s.media_attached_ca_count, 0) AS media_attached_ca_count,
            COALESCE(s.media_gross_proxy, 0) AS media_gross_proxy,
            COALESCE(s.addon_margin_proxy, 0) AS addon_margin_proxy
        FROM lk_asset_month AS a
        LEFT JOIN service AS s
               ON s.month_end = a.month_end AND s.homeid = a.homeid
    ),
active_servcos AS (
    SELECT month_end, fibernode,
           COUNT(DISTINCT servco_id) AS active_servco_count
    FROM lk_active_ca
    GROUP BY month_end, fibernode
)
SELECT
    h.month_end,
    h.region,
    h.fibernode,
    h.urban_rural,
    h.exclusive_cohort,
    h.access_period,
    COALESCE(MAX(a.active_servco_count), 0) AS active_servco_count,
    COUNT(*) AS homepasses,
    COUNT(*) FILTER (WHERE h.snapshot_observed) AS observed_homepasses,
    SUM(h.active_ca_count) AS active_ca,
    COUNT(*) FILTER (WHERE h.active_ca_count > 0) AS occupied_homepasses,
    ROUND(100.0 * SUM(h.active_ca_count) / NULLIF(COUNT(*), 0), 2) AS ca_penetration_pct,
    SUM(h.capex_cost) AS capex_total,
    SUM(h.lease_proxy) AS lease_proxy,
    ROUND(SUM(h.lease_proxy) / NULLIF(COUNT(*), 0), 0) AS lease_per_homepass_proxy,
    SUM(h.media_attached_ca_count) AS media_attached_ca,
    ROUND(100.0 * SUM(h.media_attached_ca_count) / NULLIF(SUM(h.active_ca_count), 0), 2) AS media_attach_pct,
    SUM(h.media_gross_proxy) AS media_gross_proxy,
    SUM(h.addon_margin_proxy) AS addon_margin_proxy
FROM lk_month_home AS h
LEFT JOIN active_servcos AS a
       ON a.month_end = h.month_end AND a.fibernode = h.fibernode
GROUP BY h.month_end, h.region, h.fibernode, h.urban_rural,
         h.exclusive_cohort, h.access_period
ORDER BY h.month_end, h.fibernode;

-- T04 -> servco_month.csv
WITH
    lk_homepass AS (
        SELECT
            h.homeid,
            h.region,
            h.fibernode,
            r.island,
            r.urban_rural,
            h.technology,
            h.build_date::timestamp::date AS build_date,
            h.capex_cost::numeric AS capex_cost,
            h.exclusive_flag,
            h.exclusive_servco_id,
            NULLIF(BTRIM(h.exclusive_start_date), '')::date AS exclusive_start_date,
            NULLIF(BTRIM(h.exclusive_end_date), '')::date AS exclusive_end_date,
            CASE WHEN h.exclusive_flag = 'Y' THEN 'EVER_EXCLUSIVE'
                 ELSE 'NEVER_EXCLUSIVE' END AS exclusive_cohort
        FROM linknet_assesment.homepass_fin AS h
        LEFT JOIN linknet_assesment.region_master_fin AS r
               ON r.fibernode = h.fibernode
    ),
    lk_months AS (
        SELECT DISTINCT snapshot_date::timestamp::date AS month_end
        FROM linknet_assesment.subscription_snapshot_fin
    ),
    lk_asset_month AS (
        SELECT
            m.month_end,
            h.*,
            (o.homeid IS NOT NULL) AS snapshot_observed,
            CASE
                WHEN h.exclusive_flag <> 'Y' THEN 'NEVER_EXCLUSIVE'
                WHEN m.month_end < h.exclusive_start_date THEN 'PRE_EXCLUSIVE'
                WHEN m.month_end <= h.exclusive_end_date THEN 'EXCLUSIVE_WINDOW'
                ELSE 'POST_EXCLUSIVE'
            END AS access_period
        FROM lk_months AS m
        CROSS JOIN lk_homepass AS h
        LEFT JOIN (
            SELECT DISTINCT snapshot_date::timestamp::date AS month_end, homeid
            FROM linknet_assesment.subscription_snapshot_fin
        ) AS o ON o.month_end = m.month_end AND o.homeid = h.homeid
    ),
    lk_active_ca AS (
        SELECT
            a.month_end,
            s.homeid,
            s.servco_id,
            s.contract_account,
            s.bandwidth_mbps,
            a.region,
            a.fibernode,
            a.urban_rural,
            a.technology,
            a.exclusive_cohort,
            a.access_period,
            v.servco_name,
            v.lease_fee_per_active::numeric AS lease_proxy,
            (m.contract_account IS NOT NULL) AS media_attached,
            m.catv_package,
            m.add_on_product,
            m.package_price,
            m.ao_wholesale_price,
            m.ao_rrp_price,
            CASE WHEN m.contract_account IS NULL THEN 0::numeric
                 ELSE (m.package_price + m.ao_rrp_price)::numeric
            END AS media_gross_proxy,
            CASE WHEN m.contract_account IS NULL THEN 0::numeric
                 ELSE (m.ao_rrp_price - m.ao_wholesale_price)::numeric
            END AS addon_margin_proxy
        FROM linknet_assesment.subscription_snapshot_fin AS s
        JOIN lk_asset_month AS a
          ON a.month_end = s.snapshot_date::timestamp::date AND a.homeid = s.homeid
        JOIN linknet_assesment.servco_fin AS v ON v.servco_id = s.servco_id
        LEFT JOIN linknet_assesment.media_package_fin AS m
               ON m.contract_account = s.contract_account
        WHERE s.status = 'ACTIVE'
          AND s.active_flag = 1
          AND NULLIF(BTRIM(s.contract_account), '') IS NOT NULL
    ),
access_base AS (
    SELECT a.month_end, s.servco_id,
           COUNT(*) FILTER (
               WHERE a.access_period <> 'EXCLUSIVE_WINDOW'
                  OR a.exclusive_servco_id = s.servco_id
           ) AS modeled_accessible_homepasses
    FROM lk_asset_month AS a
    CROSS JOIN linknet_assesment.servco_fin AS s
    GROUP BY a.month_end, s.servco_id
), measured AS (
    SELECT month_end, servco_id,
           COUNT(DISTINCT contract_account) AS active_ca,
           SUM(lease_proxy) AS lease_proxy,
           COUNT(DISTINCT contract_account) FILTER (WHERE media_attached) AS media_attached_ca,
           SUM(media_gross_proxy) AS media_gross_proxy,
           SUM(addon_margin_proxy) AS addon_margin_proxy
    FROM lk_active_ca
    GROUP BY month_end, servco_id
), series AS (
    SELECT a.month_end, a.servco_id, s.servco_name,
           a.modeled_accessible_homepasses,
           COALESCE(m.active_ca, 0) AS active_ca,
           COALESCE(m.lease_proxy, 0) AS lease_proxy,
           COALESCE(m.media_attached_ca, 0) AS media_attached_ca,
           COALESCE(m.media_gross_proxy, 0) AS media_gross_proxy,
           COALESCE(m.addon_margin_proxy, 0) AS addon_margin_proxy
    FROM access_base AS a
    JOIN linknet_assesment.servco_fin AS s USING (servco_id)
    LEFT JOIN measured AS m
           ON m.month_end = a.month_end AND m.servco_id = a.servco_id
)
SELECT
    month_end,
    servco_id,
    servco_name,
    active_ca,
    (SELECT COUNT(*) FROM lk_homepass) AS portfolio_homepasses,
    ROUND(100.0 * active_ca / NULLIF((SELECT COUNT(*) FROM lk_homepass), 0), 2) AS portfolio_ca_density_pct,
    modeled_accessible_homepasses,
    ROUND(100.0 * active_ca / NULLIF(modeled_accessible_homepasses, 0), 2) AS modeled_accessible_penetration_pct,
    lease_proxy,
    ROUND(100.0 * lease_proxy / NULLIF(SUM(lease_proxy) OVER (PARTITION BY month_end), 0), 2) AS lease_share_pct,
    media_attached_ca,
    ROUND(100.0 * media_attached_ca / NULLIF(active_ca, 0), 2) AS media_attach_pct,
    media_gross_proxy,
    addon_margin_proxy
FROM series
ORDER BY month_end, servco_id;

-- T05 -> media_product_december.csv
WITH
    lk_homepass AS (
        SELECT
            h.homeid,
            h.region,
            h.fibernode,
            r.island,
            r.urban_rural,
            h.technology,
            h.build_date::timestamp::date AS build_date,
            h.capex_cost::numeric AS capex_cost,
            h.exclusive_flag,
            h.exclusive_servco_id,
            NULLIF(BTRIM(h.exclusive_start_date), '')::date AS exclusive_start_date,
            NULLIF(BTRIM(h.exclusive_end_date), '')::date AS exclusive_end_date,
            CASE WHEN h.exclusive_flag = 'Y' THEN 'EVER_EXCLUSIVE'
                 ELSE 'NEVER_EXCLUSIVE' END AS exclusive_cohort
        FROM linknet_assesment.homepass_fin AS h
        LEFT JOIN linknet_assesment.region_master_fin AS r
               ON r.fibernode = h.fibernode
    ),
    lk_months AS (
        SELECT DISTINCT snapshot_date::timestamp::date AS month_end
        FROM linknet_assesment.subscription_snapshot_fin
    ),
    lk_asset_month AS (
        SELECT
            m.month_end,
            h.*,
            (o.homeid IS NOT NULL) AS snapshot_observed,
            CASE
                WHEN h.exclusive_flag <> 'Y' THEN 'NEVER_EXCLUSIVE'
                WHEN m.month_end < h.exclusive_start_date THEN 'PRE_EXCLUSIVE'
                WHEN m.month_end <= h.exclusive_end_date THEN 'EXCLUSIVE_WINDOW'
                ELSE 'POST_EXCLUSIVE'
            END AS access_period
        FROM lk_months AS m
        CROSS JOIN lk_homepass AS h
        LEFT JOIN (
            SELECT DISTINCT snapshot_date::timestamp::date AS month_end, homeid
            FROM linknet_assesment.subscription_snapshot_fin
        ) AS o ON o.month_end = m.month_end AND o.homeid = h.homeid
    ),
    lk_active_ca AS (
        SELECT
            a.month_end,
            s.homeid,
            s.servco_id,
            s.contract_account,
            s.bandwidth_mbps,
            a.region,
            a.fibernode,
            a.urban_rural,
            a.technology,
            a.exclusive_cohort,
            a.access_period,
            v.servco_name,
            v.lease_fee_per_active::numeric AS lease_proxy,
            (m.contract_account IS NOT NULL) AS media_attached,
            m.catv_package,
            m.add_on_product,
            m.package_price,
            m.ao_wholesale_price,
            m.ao_rrp_price,
            CASE WHEN m.contract_account IS NULL THEN 0::numeric
                 ELSE (m.package_price + m.ao_rrp_price)::numeric
            END AS media_gross_proxy,
            CASE WHEN m.contract_account IS NULL THEN 0::numeric
                 ELSE (m.ao_rrp_price - m.ao_wholesale_price)::numeric
            END AS addon_margin_proxy
        FROM linknet_assesment.subscription_snapshot_fin AS s
        JOIN lk_asset_month AS a
          ON a.month_end = s.snapshot_date::timestamp::date AND a.homeid = s.homeid
        JOIN linknet_assesment.servco_fin AS v ON v.servco_id = s.servco_id
        LEFT JOIN linknet_assesment.media_package_fin AS m
               ON m.contract_account = s.contract_account
        WHERE s.status = 'ACTIVE'
          AND s.active_flag = 1
          AND NULLIF(BTRIM(s.contract_account), '') IS NOT NULL
    )
SELECT
    month_end,
    catv_package,
    add_on_product,
    COUNT(DISTINCT contract_account) AS attached_ca,
    SUM(package_price) AS catv_price_proxy,
    SUM(ao_rrp_price) AS addon_rrp_proxy,
    SUM(ao_wholesale_price) AS addon_wholesale_proxy,
    SUM(addon_margin_proxy) AS addon_margin_proxy
FROM lk_active_ca
WHERE month_end = DATE '2025-12-31' AND media_attached
GROUP BY month_end, catv_package, add_on_product
ORDER BY catv_package, add_on_product;

-- T06 -> node_peer_benchmark_december.csv
WITH
    lk_homepass AS (
        SELECT
            h.homeid,
            h.region,
            h.fibernode,
            r.island,
            r.urban_rural,
            h.technology,
            h.build_date::timestamp::date AS build_date,
            h.capex_cost::numeric AS capex_cost,
            h.exclusive_flag,
            h.exclusive_servco_id,
            NULLIF(BTRIM(h.exclusive_start_date), '')::date AS exclusive_start_date,
            NULLIF(BTRIM(h.exclusive_end_date), '')::date AS exclusive_end_date,
            CASE WHEN h.exclusive_flag = 'Y' THEN 'EVER_EXCLUSIVE'
                 ELSE 'NEVER_EXCLUSIVE' END AS exclusive_cohort
        FROM linknet_assesment.homepass_fin AS h
        LEFT JOIN linknet_assesment.region_master_fin AS r
               ON r.fibernode = h.fibernode
    ),
    lk_months AS (
        SELECT DISTINCT snapshot_date::timestamp::date AS month_end
        FROM linknet_assesment.subscription_snapshot_fin
    ),
    lk_asset_month AS (
        SELECT
            m.month_end,
            h.*,
            (o.homeid IS NOT NULL) AS snapshot_observed,
            CASE
                WHEN h.exclusive_flag <> 'Y' THEN 'NEVER_EXCLUSIVE'
                WHEN m.month_end < h.exclusive_start_date THEN 'PRE_EXCLUSIVE'
                WHEN m.month_end <= h.exclusive_end_date THEN 'EXCLUSIVE_WINDOW'
                ELSE 'POST_EXCLUSIVE'
            END AS access_period
        FROM lk_months AS m
        CROSS JOIN lk_homepass AS h
        LEFT JOIN (
            SELECT DISTINCT snapshot_date::timestamp::date AS month_end, homeid
            FROM linknet_assesment.subscription_snapshot_fin
        ) AS o ON o.month_end = m.month_end AND o.homeid = h.homeid
    ),
    lk_active_ca AS (
        SELECT
            a.month_end,
            s.homeid,
            s.servco_id,
            s.contract_account,
            s.bandwidth_mbps,
            a.region,
            a.fibernode,
            a.urban_rural,
            a.technology,
            a.exclusive_cohort,
            a.access_period,
            v.servco_name,
            v.lease_fee_per_active::numeric AS lease_proxy,
            (m.contract_account IS NOT NULL) AS media_attached,
            m.catv_package,
            m.add_on_product,
            m.package_price,
            m.ao_wholesale_price,
            m.ao_rrp_price,
            CASE WHEN m.contract_account IS NULL THEN 0::numeric
                 ELSE (m.package_price + m.ao_rrp_price)::numeric
            END AS media_gross_proxy,
            CASE WHEN m.contract_account IS NULL THEN 0::numeric
                 ELSE (m.ao_rrp_price - m.ao_wholesale_price)::numeric
            END AS addon_margin_proxy
        FROM linknet_assesment.subscription_snapshot_fin AS s
        JOIN lk_asset_month AS a
          ON a.month_end = s.snapshot_date::timestamp::date AND a.homeid = s.homeid
        JOIN linknet_assesment.servco_fin AS v ON v.servco_id = s.servco_id
        LEFT JOIN linknet_assesment.media_package_fin AS m
               ON m.contract_account = s.contract_account
        WHERE s.status = 'ACTIVE'
          AND s.active_flag = 1
          AND NULLIF(BTRIM(s.contract_account), '') IS NOT NULL
    ),
    lk_month_home AS (
        WITH service AS (
            SELECT
                month_end,
                homeid,
                COUNT(DISTINCT contract_account) AS active_ca_count,
                COUNT(DISTINCT servco_id) AS active_servco_count,
                COUNT(DISTINCT contract_account) FILTER (WHERE servco_id = 101)
                    AS xls_active_ca_count,
                COUNT(DISTINCT contract_account) FILTER (WHERE servco_id <> 101)
                    AS other_active_ca_count,
                SUM(lease_proxy) AS lease_proxy,
                COUNT(DISTINCT contract_account) FILTER (WHERE media_attached)
                    AS media_attached_ca_count,
                SUM(media_gross_proxy) AS media_gross_proxy,
                SUM(addon_margin_proxy) AS addon_margin_proxy
            FROM lk_active_ca
            GROUP BY month_end, homeid
        )
        SELECT
            a.month_end,
            a.homeid,
            a.region,
            a.fibernode,
            a.island,
            a.urban_rural,
            a.technology,
            a.build_date,
            a.capex_cost,
            a.exclusive_flag,
            a.exclusive_servco_id,
            a.exclusive_cohort,
            a.access_period,
            a.snapshot_observed,
            COALESCE(s.active_ca_count, 0) AS active_ca_count,
            COALESCE(s.active_servco_count, 0) AS active_servco_count,
            COALESCE(s.xls_active_ca_count, 0) AS xls_active_ca_count,
            COALESCE(s.other_active_ca_count, 0) AS other_active_ca_count,
            COALESCE(s.lease_proxy, 0) AS lease_proxy,
            COALESCE(s.media_attached_ca_count, 0) AS media_attached_ca_count,
            COALESCE(s.media_gross_proxy, 0) AS media_gross_proxy,
            COALESCE(s.addon_margin_proxy, 0) AS addon_margin_proxy
        FROM lk_asset_month AS a
        LEFT JOIN service AS s
               ON s.month_end = a.month_end AND s.homeid = a.homeid
    ),
    lk_node_benchmark AS (
        WITH node_december AS (
            SELECT
                region,
                fibernode,
                urban_rural,
                exclusive_cohort,
                COUNT(*) AS homepasses,
                SUM(active_ca_count) AS active_ca,
                SUM(lease_proxy) AS lease_proxy,
                SUM(capex_cost) AS capex_total
            FROM lk_month_home
            WHERE month_end = DATE '2025-12-31'
            GROUP BY region, fibernode, urban_rural, exclusive_cohort
        ),
        regional_peer AS (
            SELECT region,
                   SUM(homepasses) AS peer_homepasses,
                   SUM(active_ca) AS peer_active_ca,
                   SUM(lease_proxy) AS peer_lease_proxy
            FROM node_december
            WHERE exclusive_cohort = 'NEVER_EXCLUSIVE'
            GROUP BY region
        ),
        matched AS (
            SELECT
                n.*,
                p.peer_homepasses,
                p.peer_active_ca,
                p.peer_lease_proxy,
                GREATEST(
                    0::numeric,
                    n.homepasses * p.peer_active_ca::numeric
                        / NULLIF(p.peer_homepasses, 0) - n.active_ca
                ) AS benchmark_gap_ca
            FROM node_december AS n
            JOIN regional_peer AS p USING (region)
            WHERE n.exclusive_cohort = 'EVER_EXCLUSIVE'
        )
        SELECT
            matched.*,
            benchmark_gap_ca * peer_lease_proxy::numeric
                / NULLIF(peer_active_ca, 0) AS benchmark_lease_gap
        FROM matched
    )
SELECT
    DATE '2025-12-31' AS month_end,
    region,
    fibernode,
    homepasses,
    active_ca,
    ROUND(100.0 * active_ca / NULLIF(homepasses, 0), 2) AS ca_penetration_pct,
    capex_total,
    peer_homepasses,
    peer_active_ca,
    ROUND(100.0 * peer_active_ca / NULLIF(peer_homepasses, 0), 2) AS peer_ca_penetration_pct,
    ROUND(benchmark_gap_ca, 2) AS benchmark_gap_ca,
    ROUND(benchmark_lease_gap, 2) AS benchmark_lease_gap_proxy
FROM lk_node_benchmark
ORDER BY fibernode;
