-- Per-account visibility, set by the owner of the account in their own
-- settings (the server-wide `user_directory` switch stays the administrator's
-- and wins over all of them).
--
-- `find_me_in_search` hides the account from the directory listing only; an
-- exact lookup by username still answers, because that is where a client
-- fetches the keys it is about to encrypt to (PROTOCOL.md §7).
-- `show_online` hides presence and the last-seen time from other members.
-- `allow_group_add` refuses a group invitation from somebody the account has
-- never talked to.
--
-- All three default to 1: an upgrade must not make every existing account —
-- bots included, they live in this table too — vanish from the directory.
ALTER TABLE accounts ADD COLUMN find_me_in_search INTEGER NOT NULL DEFAULT 1;
ALTER TABLE accounts ADD COLUMN show_online INTEGER NOT NULL DEFAULT 1;
ALTER TABLE accounts ADD COLUMN allow_group_add INTEGER NOT NULL DEFAULT 1;
