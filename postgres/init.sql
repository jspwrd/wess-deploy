-- WESS Database Schema
-- Tables for satellite TLE (Two-Line Element) data

CREATE TABLE IF NOT EXISTS nasa_tles (
    satellite_id INTEGER NOT NULL PRIMARY KEY,
    context TEXT NOT NULL DEFAULT '',
    tle_id TEXT NOT NULL DEFAULT '',
    type TEXT NOT NULL DEFAULT '',
    name TEXT NOT NULL DEFAULT '',
    date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    line1 TEXT NOT NULL DEFAULT '',
    line2 TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS tles (
    satellite_id INTEGER NOT NULL PRIMARY KEY,
    name TEXT NOT NULL DEFAULT '',
    date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    sat_cat INTEGER NOT NULL DEFAULT 0,
    checksum_line1 SMALLINT NOT NULL DEFAULT 0,
    checksum_line2 SMALLINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS tle_line1 (
    satellite_id INTEGER NOT NULL PRIMARY KEY,
    classification TEXT,
    launch_year SMALLINT NOT NULL DEFAULT 0,
    launch_of_year SMALLINT NOT NULL DEFAULT 0,
    piece_of_launch TEXT,
    epoch_year SMALLINT NOT NULL DEFAULT 0,
    epoch_day REAL NOT NULL DEFAULT 0,
    first_derivative_mean_motion REAL NOT NULL DEFAULT 0,
    second_derivative_mean_motion REAL NOT NULL DEFAULT 0,
    drag REAL NOT NULL DEFAULT 0,
    ephemeris SMALLINT NOT NULL DEFAULT 0,
    element_set SMALLINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS tle_line2 (
    satellite_id INTEGER NOT NULL PRIMARY KEY,
    inclination REAL NOT NULL DEFAULT 0,
    raan REAL NOT NULL DEFAULT 0,
    eccentricity REAL NOT NULL DEFAULT 0,
    argument_of_perigee REAL NOT NULL DEFAULT 0,
    mean_anomaly REAL NOT NULL DEFAULT 0,
    mean_motion REAL NOT NULL DEFAULT 0,
    rev INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- View that joins tles + tle_line1 + tle_line2 for the wess-backend API
CREATE OR REPLACE VIEW tles_complete AS
SELECT
    t.satellite_id,
    t.name,
    t.date,
    t.sat_cat,
    l1.classification,
    l1.launch_year,
    l1.launch_of_year,
    l1.piece_of_launch,
    l1.epoch_year,
    l1.epoch_day,
    l1.first_derivative_mean_motion,
    l1.second_derivative_mean_motion,
    l1.drag,
    l1.ephemeris,
    l1.element_set,
    t.checksum_line1,
    l2.inclination,
    l2.raan,
    l2.eccentricity,
    l2.argument_of_perigee,
    l2.mean_anomaly,
    l2.mean_motion,
    l2.rev,
    t.checksum_line2,
    t.created_at,
    t.updated_at
FROM tles t
JOIN tle_line1 l1 ON t.satellite_id = l1.satellite_id
JOIN tle_line2 l2 ON t.satellite_id = l2.satellite_id;
