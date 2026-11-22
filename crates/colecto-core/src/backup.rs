//! Backups: one zip with `manifest.json` and the owner's data, so the app and the daemon can
//! move their accounts, drafts, labels, settings, API keys and AI data to each other.
//!
//! Without a passphrase the data is stored as plain JSON and saved passwords are left out:
//! accounts come back signed out. With a passphrase everything, passwords included, is sealed
//! with XChaCha20-Poly1305 under an Argon2id key, and the passphrase is needed to restore it.
//! Caches (message lists, downloaded content) are not backed up; they refill from the servers.
use crate::{
    Database, Error, SCHEMA_VERSION, Value,
    credentials::{SavedAccount, Secrets},
    storage,
};
use argon2::{Algorithm, Argon2, Params, Version};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use chacha20poly1305::{
    XChaCha20Poly1305, XNonce,
    aead::{Aead, AeadCore, KeyInit, OsRng, Payload as AeadPayload, rand_core::RngCore},
};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    io::{Cursor, Read, Write},
};
use zeroize::Zeroizing;

const FORMAT: &str = "colecto-backup";
const VERSION: u32 = 1;
const MANIFEST: &str = "manifest.json";
const PLAIN: &str = "data.json";
const SEALED: &str = "data.sealed";
const AAD: &[u8] = b"colecto-backup-v1";
/// The most a backup may unpack to, so a hostile file cannot exhaust memory.
const MAX_UNPACKED: u64 = 512 * 1024 * 1024;
/// Argon2id at 64 MiB, 3 passes, one lane: the same cost as the credential vault.
const KDF: (u32, u32, u32) = (65536, 3, 1);

/// Backed-up tables and their columns, in the order rows are written back.
const TABLES: &[(&str, &[&str])] = &[
    ("settings", &["scope", "key", "value"]),
    (
        "drafts",
        &[
            "account",
            "id",
            "recipient",
            "cc",
            "subject",
            "body",
            "in_reply_to",
            "message_references",
            "forward_of",
        ],
    ),
    ("labels", &["account", "name"]),
    ("label_messages", &["account", "label", "message"]),
    (
        "api_keys",
        &[
            "id",
            "name",
            "accounts",
            "capabilities",
            "created_at",
            "expires_at",
            "last_used_at",
            "revoked_at",
            "verifier",
        ],
    ),
    (
        "ai_summaries",
        &["account", "message_id", "summary", "created_at"],
    ),
    ("ai_autolabel_seen", &["account", "message_id", "seen_at"]),
];
/// Caches and short-lived rows, emptied on restore because they belong to the old data.
const CLEARED: &[&str] = &[
    "snapshots",
    "mailbox_identity",
    "message_content",
    "send_approvals",
];

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Cell {
    Null,
    Integer(i64),
    Real(f64),
    Text(String),
    /// Base64.
    Blob(String),
}

impl Cell {
    fn from_value(value: Value) -> Self {
        match value {
            Value::Null => Self::Null,
            Value::Integer(v) => Self::Integer(v),
            Value::Real(v) => Self::Real(v),
            Value::Text(v) => Self::Text(v),
            Value::Blob(v) => Self::Blob(STANDARD.encode(v)),
        }
    }
    fn into_value(self) -> Result<Value, Error> {
        Ok(match self {
            Self::Null => Value::Null,
            Self::Integer(v) => Value::Integer(v),
            Self::Real(v) => Value::Real(v),
            Self::Text(v) => Value::Text(v),
            Self::Blob(v) => Value::Blob(STANDARD.decode(v).map_err(|_| damaged())?),
        })
    }
}

/// What a backup holds.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Contents {
    pub accounts: Vec<SavedAccount>,
    /// Saved passwords and service keys; only in a backup sealed with a passphrase.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub secrets: Option<Secrets>,
    tables: BTreeMap<String, Vec<Vec<Cell>>>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    format: String,
    version: u32,
    /// The database schema the rows were written with.
    schema: i64,
    created_at: u64,
    app_version: String,
    accounts: usize,
    credentials: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    sealed: Option<Sealing>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Sealing {
    kdf: String,
    memory_kib: u32,
    iterations: u32,
    lanes: u32,
    salt: String,
    nonce: String,
}

fn damaged() -> Error {
    Error::Invalid("This file is not a Colecto backup, or it is damaged".into())
}

/// Checks a backup passphrase before anything is written with it.
pub(crate) fn check_passphrase(passphrase: &str) -> Result<(), Error> {
    if passphrase.chars().count() < 8 || passphrase.len() > 1024 {
        return Err(Error::Invalid(
            "Use a backup passphrase of at least 8 characters".into(),
        ));
    }
    Ok(())
}

fn derive(
    passphrase: &str,
    salt: &[u8],
    (memory, iterations, lanes): (u32, u32, u32),
) -> Result<Zeroizing<[u8; 32]>, Error> {
    // Refuse settings that would take minutes, or make the key cheap to guess.
    if !(8192..=1_048_576).contains(&memory)
        || !(1..=10).contains(&iterations)
        || !(1..=8).contains(&lanes)
    {
        return Err(damaged());
    }
    let mut key = Zeroizing::new([0; 32]);
    let params = Params::new(memory, iterations, lanes, Some(32)).map_err(storage)?;
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
        .hash_password_into(passphrase.as_bytes(), salt, key.as_mut())
        .map_err(storage)?;
    Ok(key)
}

/// Reads every backed-up table.
pub(crate) fn dump(
    database: &Database,
    accounts: Vec<SavedAccount>,
    secrets: Option<Secrets>,
) -> Result<Contents, Error> {
    let mut tables = BTreeMap::new();
    for (table, columns) in TABLES {
        let rows = database.query(
            &format!("SELECT {} FROM {table} ORDER BY rowid", columns.join(",")),
            vec![],
        )?;
        let rows = rows
            .into_iter()
            .map(|row| {
                (0..columns.len())
                    .map(|i| row.value_at(i).map(Cell::from_value))
                    .collect::<Result<Vec<_>, _>>()
            })
            .collect::<Result<Vec<_>, _>>()?;
        tables.insert((*table).to_owned(), rows);
    }
    Ok(Contents {
        accounts,
        secrets,
        tables,
    })
}

/// Packs a backup; `passphrase` seals it and keeps the saved passwords in it.
pub(crate) fn pack(
    contents: &Contents,
    passphrase: Option<&str>,
    app_version: &str,
    now: u64,
) -> Result<Vec<u8>, Error> {
    let data = Zeroizing::new(serde_json::to_vec(contents).map_err(storage)?);
    let (name, body, sealed) = match passphrase {
        Some(passphrase) => {
            check_passphrase(passphrase)?;
            // A fresh random salt for every backup.
            let salt = [OsRng.next_u64(), OsRng.next_u64()]
                .map(u64::to_le_bytes)
                .concat();
            let key = derive(passphrase, &salt, KDF)?;
            let nonce = XChaCha20Poly1305::generate_nonce(&mut OsRng);
            let ciphertext = XChaCha20Poly1305::new((&*key).into())
                .encrypt(
                    &nonce,
                    AeadPayload {
                        msg: &data,
                        aad: AAD,
                    },
                )
                .map_err(|_| Error::Invalid("Could not encrypt the backup".into()))?;
            let sealing = Sealing {
                kdf: "argon2id".into(),
                memory_kib: KDF.0,
                iterations: KDF.1,
                lanes: KDF.2,
                salt: STANDARD.encode(salt),
                nonce: STANDARD.encode(nonce),
            };
            (SEALED, ciphertext, Some(sealing))
        }
        None => (PLAIN, data.to_vec(), None),
    };
    let manifest = Manifest {
        format: FORMAT.into(),
        version: VERSION,
        schema: SCHEMA_VERSION,
        created_at: now,
        app_version: app_version.into(),
        accounts: contents.accounts.len(),
        credentials: contents.secrets.is_some(),
        sealed,
    };
    let mut zip = zip::ZipWriter::new(Cursor::new(Vec::new()));
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);
    zip.start_file(MANIFEST, options).map_err(storage)?;
    zip.write_all(&serde_json::to_vec_pretty(&manifest).map_err(storage)?)
        .map_err(storage)?;
    // Sealed data does not compress; storing it saves time.
    let body_options = if manifest.sealed.is_some() {
        options.compression_method(zip::CompressionMethod::Stored)
    } else {
        options
    };
    zip.start_file(name, body_options).map_err(storage)?;
    zip.write_all(&body).map_err(storage)?;
    Ok(zip.finish().map_err(storage)?.into_inner())
}

fn entry(archive: &mut zip::ZipArchive<Cursor<&[u8]>>, name: &str) -> Result<Vec<u8>, Error> {
    let file = archive.by_name(name).map_err(|_| damaged())?;
    let mut out = Vec::new();
    file.take(MAX_UNPACKED + 1)
        .read_to_end(&mut out)
        .map_err(|_| damaged())?;
    if out.len() as u64 > MAX_UNPACKED {
        return Err(Error::Invalid("This backup is too large".into()));
    }
    Ok(out)
}

/// Opens a backup. A sealed one needs its passphrase.
pub(crate) fn unpack(bytes: &[u8], passphrase: Option<&str>) -> Result<Contents, Error> {
    let mut archive = zip::ZipArchive::new(Cursor::new(bytes)).map_err(|_| damaged())?;
    let manifest: Manifest =
        serde_json::from_slice(&entry(&mut archive, MANIFEST)?).map_err(|_| damaged())?;
    if manifest.format != FORMAT {
        return Err(damaged());
    }
    if manifest.version > VERSION || manifest.schema > SCHEMA_VERSION {
        return Err(Error::Invalid(
            "This backup was made by a newer Colecto. Update Colecto, then restore it.".into(),
        ));
    }
    let data = match &manifest.sealed {
        None => Zeroizing::new(entry(&mut archive, PLAIN)?),
        Some(sealing) => {
            let passphrase = passphrase.filter(|p| !p.is_empty()).ok_or_else(|| {
                Error::Invalid("This backup is locked. Enter its passphrase.".into())
            })?;
            if sealing.kdf != "argon2id" {
                return Err(damaged());
            }
            let salt = STANDARD.decode(&sealing.salt).map_err(|_| damaged())?;
            let nonce = STANDARD.decode(&sealing.nonce).map_err(|_| damaged())?;
            if salt.len() < 16 || nonce.len() != 24 {
                return Err(damaged());
            }
            let key = derive(
                passphrase,
                &salt,
                (sealing.memory_kib, sealing.iterations, sealing.lanes),
            )?;
            let ciphertext = entry(&mut archive, SEALED)?;
            Zeroizing::new(
                XChaCha20Poly1305::new((&*key).into())
                    .decrypt(
                        XNonce::from_slice(&nonce),
                        AeadPayload {
                            msg: &ciphertext,
                            aad: AAD,
                        },
                    )
                    .map_err(|_| {
                        Error::Invalid("Wrong passphrase, or the backup is damaged".into())
                    })?,
            )
        }
    };
    let contents: Contents = serde_json::from_slice(&data).map_err(|_| damaged())?;
    for (table, rows) in &contents.tables {
        let columns = TABLES
            .iter()
            .find(|(name, _)| name == table)
            .ok_or_else(damaged)?
            .1;
        if rows.iter().any(|row| row.len() != columns.len()) {
            return Err(damaged());
        }
    }
    Ok(contents)
}

/// Replaces the backed-up tables with the backup's rows, and empties caches, in one
/// transaction. Account vault and stores are the caller's.
pub(crate) fn restore_tables(database: &Database, contents: &mut Contents) -> Result<(), Error> {
    let mut statements: Vec<(String, Vec<Value>)> = Vec::new();
    for table in CLEARED.iter().chain(TABLES.iter().map(|(t, _)| t)) {
        statements.push((format!("DELETE FROM {table}"), vec![]));
    }
    // Per-account records (cached folder lists) belong to the old accounts.
    statements.push((
        "DELETE FROM records WHERE namespace LIKE 'account:%'".into(),
        vec![],
    ));
    for (table, columns) in TABLES {
        let Some(rows) = contents.tables.remove(*table) else {
            continue;
        };
        let sql = format!(
            "INSERT INTO {table}({}) VALUES ({})",
            columns.join(","),
            (1..=columns.len())
                .map(|i| format!("?{i}"))
                .collect::<Vec<_>>()
                .join(",")
        );
        for row in rows {
            let values = row
                .into_iter()
                .map(Cell::into_value)
                .collect::<Result<Vec<_>, _>>()?;
            statements.push((sql.clone(), values));
        }
    }
    database.write(
        statements
            .iter()
            .map(|(sql, values)| (sql.as_str(), values.clone()))
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(database: &Database) -> Contents {
        database
            .write(vec![
                (
                    "INSERT INTO settings(scope,key,value) VALUES ('preferences','accent','\"#8ec5f0\"')",
                    vec![],
                ),
                (
                    "INSERT INTO labels(account,name) VALUES ('demo','Travel')",
                    vec![],
                ),
            ])
            .unwrap();
        dump(database, vec![], None).unwrap()
    }

    #[test]
    fn plain_and_sealed_backups_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let database = Database::open(dir.path()).unwrap();
        let contents = sample(&database);

        let plain = pack(&contents, None, "test", 1).unwrap();
        let mut back = unpack(&plain, None).unwrap();
        assert_eq!(back.tables["labels"].len(), 1);

        let sealed = pack(&contents, Some("correct horse"), "test", 1).unwrap();
        assert!(
            unpack(&sealed, None)
                .err()
                .unwrap()
                .to_string()
                .contains("locked")
        );
        assert!(
            unpack(&sealed, Some("wrong passphrase"))
                .err()
                .unwrap()
                .to_string()
                .contains("Wrong passphrase")
        );
        unpack(&sealed, Some("correct horse")).unwrap();

        // Restoring replaces what is there.
        database
            .write(vec![(
                "INSERT INTO labels(account,name) VALUES ('demo','Old')",
                vec![],
            )])
            .unwrap();
        restore_tables(&database, &mut back).unwrap();
        let labels = database.query("SELECT name FROM labels", vec![]).unwrap();
        assert_eq!(labels.len(), 1);
        assert_eq!(labels[0].text(0).unwrap(), "Travel");
    }

    #[test]
    fn rejects_other_files_and_newer_backups() {
        assert!(unpack(b"not a zip", None).is_err());
        let mut zip = zip::ZipWriter::new(Cursor::new(Vec::new()));
        zip.start_file(MANIFEST, zip::write::SimpleFileOptions::default())
            .unwrap();
        zip.write_all(
            format!(
                r#"{{"format":"colecto-backup","version":1,"schema":{},"created_at":0,"app_version":"x","accounts":0,"credentials":false}}"#,
                SCHEMA_VERSION + 1
            )
            .as_bytes(),
        )
        .unwrap();
        let bytes = zip.finish().unwrap().into_inner();
        assert!(
            unpack(&bytes, None)
                .err()
                .unwrap()
                .to_string()
                .contains("newer Colecto")
        );
    }
}
