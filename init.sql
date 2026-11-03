-- Safe to run repeatedly: every statement is IF NOT EXISTS.
-- Docker applies it on the first start of an empty volume; scripts\setup.ps1 re-applies it on every run.
CREATE TABLE IF NOT EXISTS support_requests (
    id SERIAL PRIMARY KEY,
    ticket_id VARCHAR(50) NOT NULL,
    customer_name VARCHAR(255),
    customer_email VARCHAR(255) NOT NULL,
    message TEXT NOT NULL,
    intent VARCHAR(100),
    sentiment VARCHAR(50),
    ai_response TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS customer_feedback (
    id SERIAL PRIMARY KEY,
    ticket_id VARCHAR(50) NOT NULL,
    rating VARCHAR(20) NOT NULL,
    feedback TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Tickets from before this column existed
ALTER TABLE support_requests ADD COLUMN IF NOT EXISTS sentiment VARCHAR(50);

-- Tickets are saved as 'pending' before the AI runs, then become 'answered' (or 'failed' if every AI retry failed).
-- Existing rows count as answered. execution_id links a ticket to its n8n execution so a failure can find it.
ALTER TABLE support_requests ADD COLUMN IF NOT EXISTS status VARCHAR(20) NOT NULL DEFAULT 'answered';
ALTER TABLE support_requests ADD COLUMN IF NOT EXISTS execution_id VARCHAR(50);

-- Source of ticket numbers: SUP-<year>-<6 digits>
CREATE SEQUENCE IF NOT EXISTS ticket_seq;

CREATE INDEX IF NOT EXISTS idx_support_requests_email ON support_requests(customer_email);
CREATE INDEX IF NOT EXISTS idx_support_requests_ticket ON support_requests(ticket_id);
CREATE INDEX IF NOT EXISTS idx_customer_feedback_ticket ON customer_feedback(ticket_id);
CREATE INDEX IF NOT EXISTS idx_support_requests_execution ON support_requests(execution_id);
-- Quick look at tickets that still need a human: SELECT * FROM support_requests WHERE status <> 'answered'
CREATE INDEX IF NOT EXISTS idx_support_requests_status ON support_requests(status) WHERE status <> 'answered';
-- The workflow looks up history with LOWER(customer_email), newest first
CREATE INDEX IF NOT EXISTS idx_support_requests_email_lower_created
    ON support_requests (LOWER(customer_email), created_at DESC);
