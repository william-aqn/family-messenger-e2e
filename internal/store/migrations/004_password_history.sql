-- A password change can no longer be undone by the account itself: the key
-- bundle is re-sealed under the new password and the old one stops working
-- (PROTOCOL.md §3.2). Since a change now only needs a signed-in device and
-- not the old password, a stranger at an unlocked phone could otherwise make
-- the account unreachable for ever. Keeping the previous generation lets the
-- server's owner put it back with one UPDATE.
ALTER TABLE accounts ADD COLUMN prev_salt BLOB;
ALTER TABLE accounts ADD COLUMN prev_auth_hash BLOB;
ALTER TABLE accounts ADD COLUMN prev_key_bundle BLOB;
ALTER TABLE accounts ADD COLUMN password_changed_at INTEGER;
