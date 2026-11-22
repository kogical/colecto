use colecto_core::{DraftInput, MailStore};

fn input(id: Option<String>, subject: &str) -> DraftInput {
    DraftInput {
        id,
        recipient: "friend@example.test".into(),
        subject: subject.into(),
        body: "Hello 世界".into(),
        ..Default::default()
    }
}

#[test]
fn sample_mail_is_readable_and_unknown_ids_are_missing() {
    let dir = tempfile::tempdir().unwrap();
    let store = MailStore::open(dir.path()).unwrap();
    assert!(!store.messages().is_empty());
    let message = store.message("welcome").unwrap();
    assert_eq!(message.subject, "Welcome to Colecto");
    assert!(message.body.contains("Colecto"));
    assert!(store.message("missing").is_none());
}

#[test]
fn drafts_survive_restart_and_updates_keep_their_id() {
    let dir = tempfile::tempdir().unwrap();
    let id;
    {
        let mut store = MailStore::open(dir.path()).unwrap();
        let draft = store.save_draft(input(None, "First")).unwrap();
        id = draft.id;
        let updated = store
            .save_draft(input(Some(id.clone()), "Revised"))
            .unwrap();
        assert_eq!(updated.id, id);
        assert_eq!(store.drafts().len(), 1);
    }
    let mut store = MailStore::open(dir.path()).unwrap();
    assert_eq!(store.draft(&id).unwrap().subject, "Revised");
    assert_eq!(store.draft(&id).unwrap().body, "Hello 世界");
    assert_ne!(store.save_draft(input(None, "Next")).unwrap().id, id);
}

#[test]
fn unknown_ids_and_oversized_inputs_do_not_mutate_storage() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = MailStore::open(dir.path()).unwrap();
    assert!(
        store
            .save_draft(input(Some("missing".into()), "Oops"))
            .is_err()
    );
    assert!(store.save_draft(input(None, &"s".repeat(1000))).is_err());
    assert!(store.drafts().is_empty());
    // Empty recipients/subjects are valid unfinished drafts.
    assert!(
        store
            .save_draft(DraftInput {
                id: None,
                recipient: String::new(),
                subject: String::new(),
                body: String::new(),
                ..Default::default()
            })
            .is_ok()
    );
}

#[test]
fn only_one_store_can_write_a_directory() {
    let dir = tempfile::tempdir().unwrap();
    let first = MailStore::open(dir.path()).unwrap();
    assert!(MailStore::open(dir.path()).is_err());
    drop(first);
    assert!(MailStore::open(dir.path()).is_ok());
}

#[test]
fn queries_sample_mail_without_losing_reader_state() {
    let directory = tempfile::tempdir().unwrap();
    let mut store = MailStore::open(directory.path()).unwrap();
    let inbox = store.query("inbox", "").unwrap();
    let total = inbox.len();
    assert!(total > 4);
    let matches = store.query("inbox", "bookshop").unwrap();
    assert_eq!(matches.len(), 1);
    assert_eq!(matches[0].sender, "Maya Chen");
    assert!(!store.query("sent", "").unwrap().is_empty());
    assert!(store.message(&inbox[0].id).is_some());
    assert!(store.query("../other", "").is_err());
    assert!(store.query("inbox", "bad\r\nquery").is_err());
    // Older pages skip the newest messages; past the end there is nothing left.
    assert_eq!(store.query_page("inbox", "", total - 1).unwrap().len(), 1);
    assert!(store.query_page("inbox", "", total).unwrap().is_empty());
    assert!(store.query_page("inbox", "", 100_001).is_err());
    // Explicit page limits bound each batch and reject zero or oversized limits.
    assert_eq!(
        store
            .query_page_with_limit("inbox", "", 0, 2)
            .unwrap()
            .len(),
        2
    );
    assert_eq!(
        store
            .query_page_with_limit("inbox", "", 2, 2)
            .unwrap()
            .len(),
        2
    );
    assert!(store.query_page_with_limit("inbox", "", 0, 0).is_err());
    assert!(store.query_page_with_limit("inbox", "", 0, 101).is_err());
    // A paged listing never replaces the saved Inbox.
    assert_eq!(store.messages().len(), total);
    // The sample account's other folders list what was moved there.
    let archived = store.query("archive", "").unwrap().len();
    store.archive(&[inbox[0].id.clone()]).unwrap();
    let archive = store.query("archive", "").unwrap();
    assert_eq!(archive.len(), archived + 1);
    assert!(archive.iter().any(|m| m.id == inbox[0].id));
}

#[test]
fn the_sample_account_files_sent_replies_in_their_conversation() {
    let directory = tempfile::tempdir().unwrap();
    let mut store = MailStore::open(directory.path()).unwrap();
    let sent = store.query("sent", "").unwrap().len();
    let original = store.message("dinner").unwrap().clone();
    store
        .send(DraftInput {
            recipient: original.address.clone(),
            subject: format!("Re: {}", original.subject),
            body: "Count me in!".into(),
            ..Default::default()
        })
        .unwrap();
    let after = store.query("sent", "").unwrap();
    assert_eq!(after.len(), sent + 1);
    let reply = after.iter().find(|m| m.body == "Count me in!").unwrap();
    assert_eq!(reply.thread, original.thread);
    assert!(store.message(&reply.id).is_some());
    // Without a recipient nothing is sent.
    assert!(
        store
            .send(DraftInput {
                subject: "No one".into(),
                ..Default::default()
            })
            .is_err()
    );
}
