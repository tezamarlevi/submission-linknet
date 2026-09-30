-- 1. Infrastructure and utilization

-- Q01 - Source cardinalities. Reconcile to the five CSV files before using
-- any analytical output. This does not validate business meaning.
WITH source_counts AS (
    SELECT 'homepass_fin' AS source_table, COUNT(*) AS rows
    FROM linknet_assesment.homepass_fin
    UNION ALL SELECT 'region_master_fin', COUNT(*)
    FROM linknet_assesment.region_master_fin
    UNION ALL SELECT 'servco_fin', COUNT(*)
    FROM linknet_assesment.servco_fin
    UNION ALL SELECT 'subscription_snapshot_fin', COUNT(*)
    FROM linknet_assesment.subscription_snapshot_fin
    UNION ALL SELECT 'media_package_fin', COUNT(*)
    FROM linknet_assesment.media_package_fin
)
SELECT * FROM source_counts
ORDER BY source_table;

-- Q02 - Portfolio trend. Penetration uses all built homepasses as the
-- denominator. Occupied-home share is a separate household measure.
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
    COUNT(*) FILTER (WHERE snapshot_observed) AS snapshot_observed_homepasses,
    SUM(active_ca_count) AS active_ca,
    COUNT(*) FILTER (WHERE active_ca_count > 0) AS occupied_homepasses,
    ROUND(100.0 * SUM(active_ca_count) / NULLIF(COUNT(*), 0), 2)
        AS ca_penetration_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE active_ca_count > 0)
          / NULLIF(COUNT(*), 0), 2) AS occupied_home_share_pct,
    SUM(lease_proxy) AS lease_proxy,
    ROUND(SUM(lease_proxy) / NULLIF(COUNT(*), 0), 0)
        AS lease_per_homepass_proxy,
    SUM(media_attached_ca_count) AS media_attached_ca,
    ROUND(100.0 * SUM(media_attached_ca_count)
          / NULLIF(SUM(active_ca_count), 0), 2) AS media_attach_pct,
    SUM(media_gross_proxy) AS media_gross_proxy,
    SUM(addon_margin_proxy) AS addon_margin_proxy
FROM lk_month_home
GROUP BY month_end
ORDER BY month_end;

-- Q03. Monthly penetration and monetization by region, technology,
-- historical exclusivity, actual access period, and their intersection.
-- Each dimension is a separate slice; do not sum across segment_type.
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
    COUNT(*) FILTER (WHERE h.snapshot_observed) AS snapshot_observed_homepasses,
    SUM(h.active_ca_count) AS active_ca,
    COUNT(*) FILTER (WHERE h.active_ca_count > 0) AS occupied_homepasses,
    ROUND(100.0 * SUM(h.active_ca_count) / NULLIF(COUNT(*), 0), 2)
        AS ca_penetration_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE h.snapshot_observed)
          / NULLIF(COUNT(*), 0), 2) AS snapshot_coverage_pct,
    SUM(h.lease_proxy) AS lease_proxy,
    ROUND(SUM(h.lease_proxy) / NULLIF(COUNT(*), 0), 0)
        AS lease_per_homepass_proxy,
    SUM(h.capex_cost) AS capex_total
FROM lk_month_home AS h
CROSS JOIN LATERAL (
    VALUES
        ('region', h.region),
        ('technology', h.technology),
        ('historical_exclusivity', h.exclusive_cohort),
        ('access_period', h.access_period),
        ('region_technology_cohort',
         CONCAT_WS(' / ', h.region, h.technology, h.exclusive_cohort))
) AS d(segment_type, segment_value)
GROUP BY h.month_end, d.segment_type, d.segment_value
ORDER BY h.month_end, d.segment_type, d.segment_value;

-- Q04. December node ranking. CAPEX per active CA is an asset-utilization
-- diagnostic, not a customer acquisition cost or investment return.
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
    lk_node_month AS (
        WITH active_servcos AS (
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
            COUNT(*) AS homepasses,
            COUNT(*) FILTER (WHERE h.snapshot_observed) AS observed_homepasses,
            SUM(h.active_ca_count) AS active_ca,
            SUM(h.lease_proxy) AS lease_proxy,
            SUM(h.capex_cost) AS capex_total,
            COALESCE(MAX(a.active_servco_count), 0) AS active_servco_count,
            CASE WHEN COALESCE(MAX(a.active_servco_count), 0) = 0 THEN 'ZERO_ACTIVE_ISP'
                 WHEN MAX(a.active_servco_count) = 1 THEN 'SINGLE_ACTIVE_ISP'
                 ELSE 'MULTI_ACTIVE_ISP' END AS observed_competition
        FROM lk_month_home AS h
        LEFT JOIN active_servcos AS a
               ON a.month_end = h.month_end AND a.fibernode = h.fibernode
        GROUP BY h.month_end, h.region, h.fibernode, h.urban_rural,
                 h.exclusive_cohort, h.access_period
    )
SELECT
    region,
    fibernode,
    urban_rural,
    exclusive_cohort,
    homepasses,
    observed_homepasses,
    active_ca,
    ROUND(100.0 * active_ca / NULLIF(homepasses, 0), 2)
        AS ca_penetration_pct,
    capex_total,
    ROUND(capex_total / NULLIF(active_ca, 0), 0)
        AS capex_per_active_ca,
    lease_proxy,
    ROUND(lease_proxy / NULLIF(homepasses, 0), 0)
        AS lease_per_homepass_proxy,
    RANK() OVER (
        ORDER BY active_ca::numeric / NULLIF(homepasses, 0),
                 capex_total DESC
    ) AS low_utilization_rank
FROM lk_node_month
WHERE month_end = DATE '2025-12-31'
ORDER BY low_utilization_rank, fibernode;

-- Q05. Regional infrastructure efficiency in December. Compare both
-- absolute CAPEX and CA/lease produced by the asset base.
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
    region,
    COUNT(*) AS homepasses,
    SUM(active_ca_count) AS active_ca,
    ROUND(100.0 * SUM(active_ca_count) / NULLIF(COUNT(*), 0), 2)
        AS ca_penetration_pct,
    SUM(capex_cost) AS capex_total,
    ROUND(SUM(capex_cost) / NULLIF(SUM(active_ca_count), 0), 0)
        AS capex_per_active_ca,
    SUM(lease_proxy) AS lease_proxy,
    ROUND(SUM(lease_proxy) / NULLIF(COUNT(*), 0), 0)
        AS lease_per_homepass_proxy
FROM lk_month_home
WHERE month_end = DATE '2025-12-31'
GROUP BY region
ORDER BY capex_per_active_ca DESC NULLS LAST;

-- Q06. FTTH versus HFC within each node, reducing confounding from
-- geography. Technology is recorded per homepass, not per whole node.
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
by_technology AS (
    SELECT region, fibernode, technology,
           COUNT(*) AS homepasses,
           SUM(active_ca_count) AS active_ca
    FROM lk_month_home
    WHERE month_end = DATE '2025-12-31'
    GROUP BY region, fibernode, technology
), paired AS (
    SELECT region, fibernode,
           MAX(homepasses) FILTER (WHERE technology = 'FTTH') AS ftth_homepasses,
           MAX(active_ca) FILTER (WHERE technology = 'FTTH') AS ftth_active_ca,
           MAX(homepasses) FILTER (WHERE technology = 'HFC') AS hfc_homepasses,
           MAX(active_ca) FILTER (WHERE technology = 'HFC') AS hfc_active_ca
    FROM by_technology
    GROUP BY region, fibernode
)
SELECT
    region, fibernode,
    ftth_homepasses, ftth_active_ca,
    ROUND(100.0 * ftth_active_ca / NULLIF(ftth_homepasses, 0), 2)
        AS ftth_penetration_pct,
    hfc_homepasses, hfc_active_ca,
    ROUND(100.0 * hfc_active_ca / NULLIF(hfc_homepasses, 0), 2)
        AS hfc_penetration_pct,
    ROUND(100.0 * (
        ftth_active_ca::numeric / NULLIF(ftth_homepasses, 0)
        - hfc_active_ca::numeric / NULLIF(hfc_homepasses, 0)
    ), 2) AS ftth_minus_hfc_percentage_points
FROM paired
ORDER BY ftth_minus_hfc_percentage_points, fibernode;

-- 2. Servco performance, guarantee scenario, and observed competition
-- Q07. Monthly Servco growth and lease share. Portfolio CA density uses
-- every built homepass; modeled-accessible penetration excludes only the
-- recorded XLS-exclusive homes during their window. Actual Servco access
-- contracts outside that window are not supplied.
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
           COUNT(DISTINCT contract_account) FILTER (WHERE media_attached)
               AS media_attached_ca
    FROM lk_active_ca
    GROUP BY month_end, servco_id
), series AS (
    SELECT a.month_end, a.servco_id, s.servco_name,
           a.modeled_accessible_homepasses,
           COALESCE(m.active_ca, 0) AS active_ca,
           COALESCE(m.lease_proxy, 0) AS lease_proxy,
           COALESCE(m.media_attached_ca, 0) AS media_attached_ca
    FROM access_base AS a
    JOIN linknet_assesment.servco_fin AS s USING (servco_id)
    LEFT JOIN measured AS m
           ON m.month_end = a.month_end AND m.servco_id = a.servco_id
)
SELECT
    month_end, servco_id, servco_name,
    active_ca,
    active_ca - LAG(active_ca) OVER (
        PARTITION BY servco_id ORDER BY month_end
    ) AS month_over_month_ca_change,
    ROUND(100.0 * active_ca / NULLIF((SELECT COUNT(*) FROM lk_homepass), 0), 2)
        AS portfolio_ca_density_pct,
    modeled_accessible_homepasses,
    ROUND(100.0 * active_ca / NULLIF(modeled_accessible_homepasses, 0), 2)
        AS modeled_accessible_penetration_pct,
    lease_proxy,
    ROUND(100.0 * lease_proxy
          / NULLIF(SUM(lease_proxy) OVER (PARTITION BY month_end), 0), 2)
        AS share_of_lease_pct,
    media_attached_ca
FROM series
ORDER BY month_end, servco_id;

-- Q08. XLS minimum guarantee, deliberately labeled as a scenario.
-- The CSV provides 0,25 but no contractual denominator or settlement rule.
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
guarantee AS (
    SELECT NULLIF(REPLACE(BTRIM(minimum_guarantee), ',', '.'), '')::numeric
               AS guarantee_ratio
    FROM linknet_assesment.servco_fin
    WHERE servco_id = 101
), monthly AS (
    SELECT month_end,
           COUNT(*) AS exclusive_cohort_homepasses,
           COUNT(*) FILTER (WHERE snapshot_observed) AS observed_homepasses,
           SUM(xls_active_ca_count) AS xls_active_ca
    FROM lk_month_home
    WHERE access_period = 'EXCLUSIVE_WINDOW'
    GROUP BY month_end
)
SELECT
    m.month_end,
    m.exclusive_cohort_homepasses,
    m.observed_homepasses,
    m.xls_active_ca,
    g.guarantee_ratio,
    ROUND(100.0 * m.xls_active_ca
          / NULLIF(m.exclusive_cohort_homepasses, 0), 2)
        AS scenario_penetration_all_exclusive_pct,
    ROUND(100.0 * m.xls_active_ca
          / NULLIF(m.observed_homepasses, 0), 2)
        AS observed_subset_ca_density_pct,
    CEIL(m.exclusive_cohort_homepasses * g.guarantee_ratio)
        AS scenario_target_ca,
    GREATEST(0, CEIL(m.exclusive_cohort_homepasses * g.guarantee_ratio)
                - m.xls_active_ca) AS scenario_ca_gap
FROM monthly AS m
CROSS JOIN guarantee AS g
ORDER BY m.month_end;

-- Q09. Full exclusive cohort versus homes observed in all 12 snapshots.
-- The second group controls for the 169 homes missing before July.
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
stable_home AS (
    SELECT homeid
    FROM lk_month_home
    WHERE exclusive_cohort = 'EVER_EXCLUSIVE'
    GROUP BY homeid
    HAVING COUNT(*) FILTER (WHERE snapshot_observed)
           = (SELECT COUNT(*) FROM lk_months)
), labeled AS (
    SELECT 'FULL_EXCLUSIVE_COHORT' AS comparison_group, h.*
    FROM lk_month_home AS h
    WHERE h.exclusive_cohort = 'EVER_EXCLUSIVE'
    UNION ALL
    SELECT 'OBSERVED_ALL_12_MONTHS' AS comparison_group, h.*
    FROM lk_month_home AS h
    JOIN stable_home AS st USING (homeid)
)
SELECT
    month_end, comparison_group,
    COUNT(*) AS cohort_homepasses,
    COUNT(*) FILTER (WHERE snapshot_observed) AS observed_homepasses,
    SUM(active_ca_count) AS active_ca,
    SUM(xls_active_ca_count) AS xls_active_ca,
    SUM(other_active_ca_count) AS other_servco_active_ca,
    ROUND(100.0 * SUM(active_ca_count) / NULLIF(COUNT(*), 0), 2)
        AS ca_penetration_pct,
    SUM(lease_proxy) AS lease_proxy
FROM labeled
GROUP BY month_end, comparison_group
ORDER BY month_end, comparison_group;

-- Q10. Node-month classification uses Servcos with active CAs, not
-- contractual access rights. In December all 20 nodes are multi-active-ISP.
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
    lk_node_month AS (
        WITH active_servcos AS (
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
            COUNT(*) AS homepasses,
            COUNT(*) FILTER (WHERE h.snapshot_observed) AS observed_homepasses,
            SUM(h.active_ca_count) AS active_ca,
            SUM(h.lease_proxy) AS lease_proxy,
            SUM(h.capex_cost) AS capex_total,
            COALESCE(MAX(a.active_servco_count), 0) AS active_servco_count,
            CASE WHEN COALESCE(MAX(a.active_servco_count), 0) = 0 THEN 'ZERO_ACTIVE_ISP'
                 WHEN MAX(a.active_servco_count) = 1 THEN 'SINGLE_ACTIVE_ISP'
                 ELSE 'MULTI_ACTIVE_ISP' END AS observed_competition
        FROM lk_month_home AS h
        LEFT JOIN active_servcos AS a
               ON a.month_end = h.month_end AND a.fibernode = h.fibernode
        GROUP BY h.month_end, h.region, h.fibernode, h.urban_rural,
                 h.exclusive_cohort, h.access_period
    )
SELECT
    month_end, region, fibernode,
    exclusive_cohort, access_period, observed_competition,
    active_servco_count, homepasses, observed_homepasses, active_ca,
    ROUND(100.0 * active_ca / NULLIF(homepasses, 0), 2)
        AS ca_penetration_pct,
    lease_proxy,
    ROUND(lease_proxy / NULLIF(homepasses, 0), 0)
        AS lease_per_homepass_proxy
FROM lk_node_month
ORDER BY month_end, region, fibernode;

-- Q11. Same-month comparison of zero, single, and multi-active-ISP
-- node groups. Keeping access_period visible exposes confounding.
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
    lk_node_month AS (
        WITH active_servcos AS (
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
            COUNT(*) AS homepasses,
            COUNT(*) FILTER (WHERE h.snapshot_observed) AS observed_homepasses,
            SUM(h.active_ca_count) AS active_ca,
            SUM(h.lease_proxy) AS lease_proxy,
            SUM(h.capex_cost) AS capex_total,
            COALESCE(MAX(a.active_servco_count), 0) AS active_servco_count,
            CASE WHEN COALESCE(MAX(a.active_servco_count), 0) = 0 THEN 'ZERO_ACTIVE_ISP'
                 WHEN MAX(a.active_servco_count) = 1 THEN 'SINGLE_ACTIVE_ISP'
                 ELSE 'MULTI_ACTIVE_ISP' END AS observed_competition
        FROM lk_month_home AS h
        LEFT JOIN active_servcos AS a
               ON a.month_end = h.month_end AND a.fibernode = h.fibernode
        GROUP BY h.month_end, h.region, h.fibernode, h.urban_rural,
                 h.exclusive_cohort, h.access_period
    )
SELECT
    month_end,
    access_period,
    observed_competition,
    COUNT(*) AS nodes,
    SUM(homepasses) AS homepasses,
    SUM(observed_homepasses) AS observed_homepasses,
    SUM(active_ca) AS active_ca,
    ROUND(100.0 * SUM(active_ca) / NULLIF(SUM(homepasses), 0), 2)
        AS ca_penetration_pct,
    SUM(lease_proxy) AS lease_proxy,
    ROUND(SUM(lease_proxy) / NULLIF(SUM(homepasses), 0), 0)
        AS lease_per_homepass_proxy
FROM lk_node_month
GROUP BY month_end, access_period, observed_competition
ORDER BY month_end, access_period, observed_competition;

-- ---------------------------------------------------------------------------
-- 3. Media attachment and unit economics
-- ---------------------------------------------------------------------------

-- Q12. December attach and add-on economics by Servco. "Strongest upsell"
-- can mean rate, attached-account volume, or add-on margin, so show all three.
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
    servco_id,
    servco_name,
    COUNT(*) AS active_ca,
    COUNT(*) FILTER (WHERE media_attached) AS media_attached_ca,
    ROUND(100.0 * COUNT(*) FILTER (WHERE media_attached)
          / NULLIF(COUNT(*), 0), 2) AS attach_pct,
    SUM(media_gross_proxy) AS media_gross_proxy,
    SUM(addon_margin_proxy) AS addon_margin_proxy,
    ROUND(SUM(addon_margin_proxy)
          / NULLIF(COUNT(*) FILTER (WHERE media_attached), 0), 0)
        AS addon_margin_per_attached_ca_proxy
FROM lk_active_ca
WHERE month_end = DATE '2025-12-31'
GROUP BY servco_id, servco_name
ORDER BY attach_pct DESC, servco_id;

-- Q13. December attach and monetization by region. The margin column only
-- covers the add-on, because CATV package cost is absent.
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
    region,
    COUNT(*) AS active_ca,
    COUNT(*) FILTER (WHERE media_attached) AS media_attached_ca,
    ROUND(100.0 * COUNT(*) FILTER (WHERE media_attached)
          / NULLIF(COUNT(*), 0), 2) AS attach_pct,
    SUM(lease_proxy) AS lease_proxy,
    SUM(media_gross_proxy) AS media_gross_proxy,
    SUM(addon_margin_proxy) AS addon_margin_proxy,
    ROUND(SUM(addon_margin_proxy) / NULLIF(COUNT(*), 0), 0)
        AS addon_margin_per_active_ca_proxy
FROM lk_active_ca
WHERE month_end = DATE '2025-12-31'
GROUP BY region
ORDER BY addon_margin_proxy DESC, region;

-- Q14. December add-on ranking. Total observed margin depends on volume;
-- per-attached-account margin is the unit economics comparison. CATV costs,
-- billing adjustments, and delivery costs are unknown.
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
    add_on_product,
    COUNT(*) AS attached_active_ca,
    MIN(ao_rrp_price) AS unit_rrp,
    MIN(ao_wholesale_price) AS unit_wholesale,
    MIN(ao_rrp_price - ao_wholesale_price) AS unit_margin_proxy,
    SUM(ao_rrp_price) AS add_on_rrp_proxy,
    SUM(ao_wholesale_price) AS add_on_wholesale_proxy,
    SUM(addon_margin_proxy) AS total_addon_margin_proxy,
    ROUND(100.0 * SUM(addon_margin_proxy)
          / NULLIF(SUM(ao_rrp_price), 0), 2) AS addon_margin_rate_pct
FROM lk_active_ca
WHERE month_end = DATE '2025-12-31'
  AND media_attached
GROUP BY add_on_product
ORDER BY total_addon_margin_proxy DESC, add_on_product;

-- Q15. Monthly listed-value bridge. Media gross is CATV listed price plus
-- add-on RRP; it is not MediaCo net revenue or verified customer ARPU.
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
    COUNT(*) AS active_ca,
    SUM(lease_proxy) AS lease_proxy,
    SUM(package_price) FILTER (WHERE media_attached) AS catv_price_proxy,
    SUM(ao_rrp_price) FILTER (WHERE media_attached) AS addon_rrp_proxy,
    SUM(media_gross_proxy) AS media_gross_proxy,
    SUM(addon_margin_proxy) AS addon_margin_proxy,
    ROUND((SUM(lease_proxy) + SUM(media_gross_proxy))
          / NULLIF(COUNT(*), 0), 0) AS gross_monetization_per_active_ca_proxy,
    ROUND(SUM(lease_proxy) / NULLIF(COUNT(*), 0), 0)
        AS lease_per_active_ca_proxy,
    ROUND(SUM(media_gross_proxy) / NULLIF(COUNT(*), 0), 0)
        AS media_gross_per_active_ca_proxy
FROM lk_active_ca
GROUP BY month_end
ORDER BY month_end;

-- Q16. Region attach opportunity scenario: close only positive gaps to the
-- December portfolio attach rate at each region's fixed active-CA base.
-- Fractional CAs are an arithmetic scenario, not forecast customer counts.
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
region_base AS (
    SELECT region,
           COUNT(*) AS active_ca,
           COUNT(*) FILTER (WHERE media_attached) AS attached_ca
    FROM lk_active_ca
    WHERE month_end = DATE '2025-12-31'
    GROUP BY region
), portfolio AS (
    SELECT SUM(attached_ca)::numeric / NULLIF(SUM(active_ca), 0)
               AS attach_rate,
           (SELECT SUM(addon_margin_proxy)::numeric
              FROM lk_active_ca
             WHERE month_end = DATE '2025-12-31')
             / NULLIF(SUM(attached_ca), 0) AS margin_per_attached_ca
    FROM region_base
)
SELECT
    r.region,
    r.active_ca,
    r.attached_ca,
    ROUND(100.0 * r.attached_ca / NULLIF(r.active_ca, 0), 2)
        AS current_attach_pct,
    ROUND(100.0 * p.attach_rate, 2) AS portfolio_attach_pct,
    ROUND(GREATEST(0::numeric,
          r.active_ca * p.attach_rate - r.attached_ca), 2)
        AS scenario_incremental_attached_ca,
    ROUND(GREATEST(0::numeric,
          r.active_ca * p.attach_rate - r.attached_ca)
          * p.margin_per_attached_ca, 0)
        AS scenario_incremental_addon_margin_proxy
FROM region_base AS r
CROSS JOIN portfolio AS p
ORDER BY scenario_incremental_addon_margin_proxy DESC, r.region;

-- ---------------------------------------------------------------------------
-- 4. Strategic deep dive: the five formerly exclusive nodes
-- ---------------------------------------------------------------------------

-- Q17. December node-level same-region peer scenario. Regional peers are
-- never-exclusive nodes; this is a benchmark, not a predicted access effect.
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
    region, fibernode, urban_rural,
    homepasses, active_ca,
    ROUND(100.0 * active_ca / NULLIF(homepasses, 0), 2)
        AS node_ca_penetration_pct,
    peer_homepasses, peer_active_ca,
    ROUND(100.0 * peer_active_ca / NULLIF(peer_homepasses, 0), 2)
        AS regional_peer_ca_penetration_pct,
    ROUND(benchmark_gap_ca, 2) AS benchmark_gap_ca,
    ROUND(benchmark_lease_gap, 0) AS benchmark_lease_gap_proxy,
    capex_total,
    ROUND(capex_total / NULLIF(active_ca, 0), 0)
        AS capex_per_active_ca
FROM lk_node_benchmark
ORDER BY benchmark_lease_gap DESC, fibernode;

-- Q18. Sensitivity to closing 25%, 50%, or 100% of the peer gap.
-- Sum before rounding, since node-level rounding would change the total.
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
    s.closure_fraction,
    ROUND(SUM(benchmark_gap_ca) * s.closure_fraction, 2)
        AS scenario_incremental_ca,
    ROUND(SUM(benchmark_lease_gap) * s.closure_fraction, 0)
        AS scenario_incremental_lease_proxy
FROM lk_node_benchmark
CROSS JOIN (VALUES (0.25::numeric), (0.50::numeric), (1.00::numeric))
    AS s(closure_fraction)
GROUP BY s.closure_fraction
ORDER BY s.closure_fraction;

-- Q19. Follow the five nodes through the end of exclusivity, July coverage
-- expansion, and December. Separating XLS and other CAs helps interpretation,
-- but the early coverage gap prevents a causal before/after estimate.
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
    region,
    fibernode,
    access_period,
    COUNT(*) AS cohort_homepasses,
    COUNT(*) FILTER (WHERE snapshot_observed) AS observed_homepasses,
    SUM(active_ca_count) AS active_ca,
    SUM(xls_active_ca_count) AS xls_active_ca,
    SUM(other_active_ca_count) AS other_servco_active_ca,
    ROUND(100.0 * SUM(active_ca_count) / NULLIF(COUNT(*), 0), 2)
        AS ca_penetration_pct,
    SUM(lease_proxy) AS lease_proxy
FROM lk_month_home
WHERE exclusive_cohort = 'EVER_EXCLUSIVE'
  AND month_end IN (DATE '2025-06-30', DATE '2025-07-31',
                    DATE '2025-12-31')
GROUP BY month_end, region, fibernode, access_period
ORDER BY fibernode, month_end;

-- Q20. Servco attach-rate headroom relative to the December portfolio rate.
-- The same average observed add-on margin is applied to each arithmetic
-- opportunity; it is not a Servco-specific sales forecast.
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
servco_base AS (
    SELECT servco_id, servco_name,
           COUNT(*) AS active_ca,
           COUNT(*) FILTER (WHERE media_attached) AS attached_ca
    FROM lk_active_ca
    WHERE month_end = DATE '2025-12-31'
    GROUP BY servco_id, servco_name
), portfolio AS (
    SELECT SUM(attached_ca)::numeric / NULLIF(SUM(active_ca), 0)
               AS attach_rate,
           (SELECT SUM(addon_margin_proxy)::numeric
              FROM lk_active_ca
             WHERE month_end = DATE '2025-12-31')
             / NULLIF(SUM(attached_ca), 0) AS margin_per_attached_ca
    FROM servco_base
)
SELECT
    s.servco_id, s.servco_name,
    s.active_ca, s.attached_ca,
    ROUND(100.0 * s.attached_ca / NULLIF(s.active_ca, 0), 2)
        AS current_attach_pct,
    ROUND(100.0 * p.attach_rate, 2) AS portfolio_attach_pct,
    ROUND(GREATEST(0::numeric,
          s.active_ca * p.attach_rate - s.attached_ca), 2)
        AS scenario_incremental_attached_ca,
    ROUND(GREATEST(0::numeric,
          s.active_ca * p.attach_rate - s.attached_ca)
          * p.margin_per_attached_ca, 0)
        AS scenario_incremental_addon_margin_proxy
FROM servco_base AS s
CROSS JOIN portfolio AS p
ORDER BY scenario_incremental_addon_margin_proxy DESC, s.servco_id;

-- Q21. Reproduces the Section 2 Servco table: January-to-December active CAs,
-- December lease share, CA density on all 1,000 homepasses, and media attach.
-- The media file is undated, so attachment is an observed CA mapping proxy.
WITH active_ca AS (
    SELECT
        s.snapshot_date::timestamp::date AS month_end,
        s.servco_id,
        s.contract_account,
        v.lease_fee_per_active::numeric AS lease_proxy,
        (m.contract_account IS NOT NULL) AS media_attached
    FROM linknet_assesment.subscription_snapshot_fin AS s
    JOIN linknet_assesment.homepass_fin AS h ON h.homeid = s.homeid
    JOIN linknet_assesment.servco_fin AS v ON v.servco_id = s.servco_id
    LEFT JOIN linknet_assesment.media_package_fin AS m
           ON m.contract_account = s.contract_account
    WHERE s.status = 'ACTIVE'
      AND s.active_flag = 1
      AND NULLIF(BTRIM(s.contract_account), '') IS NOT NULL
      AND s.snapshot_date::timestamp::date IN
          (DATE '2025-01-31', DATE '2025-12-31')
), monthly AS (
    SELECT
        month_end,
        servco_id,
        COUNT(DISTINCT contract_account) AS active_ca,
        SUM(lease_proxy) AS lease_proxy,
        COUNT(DISTINCT contract_account) FILTER (WHERE media_attached)
            AS media_attached_ca
    FROM active_ca
    GROUP BY month_end, servco_id
), january AS (
    SELECT * FROM monthly WHERE month_end = DATE '2025-01-31'
), december AS (
    SELECT * FROM monthly WHERE month_end = DATE '2025-12-31'
)
SELECT
    v.servco_id,
    v.servco_name,
    COALESCE(j.active_ca, 0) AS january_active_ca,
    COALESCE(d.active_ca, 0) AS december_active_ca,
    ROUND(100.0 * d.lease_proxy
          / NULLIF(SUM(d.lease_proxy) OVER (), 0), 2)
        AS december_lease_share_pct,
    ROUND(100.0 * d.active_ca
          / NULLIF((SELECT COUNT(*) FROM linknet_assesment.homepass_fin), 0), 2)
        AS december_ca_per_all_homepasses_pct,
    ROUND(100.0 * d.media_attached_ca / NULLIF(d.active_ca, 0), 2)
        AS december_media_attach_pct
FROM linknet_assesment.servco_fin AS v
LEFT JOIN january AS j ON j.servco_id = v.servco_id
LEFT JOIN december AS d ON d.servco_id = v.servco_id
ORDER BY december_active_ca DESC, v.servco_id;
