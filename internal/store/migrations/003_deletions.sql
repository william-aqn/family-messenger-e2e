-- Deleting a message replaces it with a record at a new sequence number,
-- so every device (also those offline at the time) learns about it in order.
ALTER TABLE messages ADD COLUMN deleted_seq INTEGER;
ALTER TABLE messages ADD COLUMN deleted_sender TEXT;
