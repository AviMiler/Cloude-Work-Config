---
name: microservices-logging-placement
description: Where to place log statements in microservice code, at what level, and with which fields, aligned with the OWASP Logging Cheat Sheet. Use this skill whenever writing or reviewing service code, controllers, middleware, message consumers, background jobs, outbound calls to other services or databases, authentication/authorization code, or error handling, even if the user does not mention logging explicitly. Assumes the logging infrastructure (logger, sinks, format, shipping) already exists; this skill covers only what to log, where, and how much.
---

# Log placement, levels and content

## Core principle
Log at boundaries (request in, call out, business event, error, security event), not inside internal logic.
Every log entry must answer: when, where, who, and what (including the outcome).

## Placement table

| Location | Level | Include | Never include |
|---|---|---|---|
| Inbound request (middleware / controller / handler) | Info always, including 4xx and 5xx (the exception itself is logged by the exception handler) | One line per request: method, route, status, duration, caller identity | Body, sensitive headers |
| Outbound call (HTTP to another service, DB, message publish) | Debug on success; Warn when duration exceeds a threshold; Warn on retry or timeout; do NOT log the final failure here, throw it up | Target, operation, duration, status, attempt number | Full payload |
| Business logic / service layer | Info only for significant business events (create, status transition, cancel); Debug for decision branches | Entity IDs, status field before and after | A line per statement, logs inside loops, full entity objects |
| Data access (repository) | Usually nothing; Warn on slow query above threshold | Operation name, duration, row count | Query text with values, record data |
| Global exception handler | Error for unexpected exceptions (with stack); Info for expected failures (not found, business rule rejection) without stack | Full exception, business context (entity IDs) | Logging the same error twice |
| Consumer / background job | Info at start and end; Warn on retry or DLQ; Error on final failure (this is the boundary) | messageId, event type, attempt number, duration | Full message body |
| Startup / shutdown | Info once; Critical if startup fails | Version, environment, dependencies checked, shutdown or failure reason | Secrets, connection strings |
| Health checks | Nothing; log only on state change | Previous state -> new state | A line per check |
| Helpers, mappers, pure logic | Nothing | | |

## Security events (OWASP: always log)
Mark each with a security event type (for example `authn_login_fail`) so they can be filtered and alerted on separately from operational logs.

| Event | Level | Include |
|---|---|---|
| Authentication success | Info | User ID, method, source |
| Authentication failure | Warn | Attempted user ID, reason, source |
| Authorization (access control) failure | Warn | User ID, action, resource |
| Session / token failure (tampered cookie, invalid or expired JWT signature) | Warn | User ID if known, failure reason |
| Input validation failure (protocol violation, bad encoding, invalid parameter name or value, value outside an allowed list) | Info; treat as suspicious, not proof of attack; alert on repetition and correlation | Field name, user ID, rule violated (not the raw value) |
| Output validation failure (unexpected record set, invalid encoding) | Warn | Operation, entity IDs |
| Deserialization failure | Warn | Type, source |
| Backend TLS / certificate failure, unexpected HTTP verb | Warn | Target or route, reason |
| Suspicious business flow (steps out of order, flow bypass, exceeding limits) | Warn | User ID, action, expected vs actual step |
| High-risk functionality | Info | Who, what, target, result |

High-risk functionality covers: user administration (add/delete users, privilege changes), any action performed with admin privileges, use of shared or break-glass accounts, access to sensitive data, cryptographic key use or rotation, data import/export (including reports), file uploads and user-generated content, and configuration changes.

## Required attributes
Most of these should come from the logging infrastructure and scopes, not be added manually per call:
- **When:** UTC timestamp from a synchronized clock; correlationId/traceId linking all events of one interaction.
- **Where:** service name and version, host/instance, route or entry point.
- **Who:** authenticated user or service identity; source address where relevant.
- **What:** event type, severity, security flag, action, target object, result (success/fail), reason.

## Data to exclude
Remove, mask, hash or omit:
- Passwords, access tokens, API keys, encryption keys, connection strings
- Session IDs (log a hash only if session tracking is needed)
- Payment card or bank account data
- Sensitive personal data and government identifiers
- Source code, commercially sensitive data, data above the log store's classification
- Data the user has not consented to, or that is illegal to collect

Handle with care (pseudonymize or minimize): file paths, internal hostnames and addresses, names, emails, phone numbers.

## Cross-cutting rules
1. correlationId is injected automatically via logging scope / middleware and propagated across services. Do not add it manually to each call.
2. An error is logged once, at the boundary (global exception handler or consumer). Inner layers, including outbound calls, throw or wrap without logging.
3. No log-then-throw in the same place.
4. In loops: one summary line (count, successes, failures), not a line per iteration.
5. Structured logging only (key=value / JSON) with constant message templates. Never build messages by string concatenation or interpolation of untrusted input; this prevents log injection (CR/LF).
6. Truncate user-supplied values to a bounded length before logging.
7. Do not drop events from "trusted" sources (internal services, monitors, scanners); add a classification field instead.
8. Production default level is Info. Logging cannot be fully disabled, and security events are never filtered out by level.
9. A failure in the logging pipeline must never crash the request or leak information.
10. Rate-limit or sample errors that repeat at high frequency, so logs cannot be flooded (including by an attacker).
11. If tracing (e.g. OpenTelemetry) already measures outbound call duration, do not add a duplicate Debug log for it.

## Level guide
- **Critical:** the service cannot run (startup failure, critical dependency unavailable).
- **Error:** the current operation failed and needs attention.
- **Warn:** abnormal event the system recovered from, threshold exceeded, or security-relevant failure.
- **Info:** significant normal event at a boundary or in the business, including expected failures and successful authentication.
- **Debug:** diagnostic detail, off in production.

## Before adding a log line
- Is this a boundary, a business event, or a security event? If not, it probably does not need a log.
- Would someone act on this during an incident or investigation? If not, demote to Debug or remove.
- Is the same event already logged in another layer? If so, remove it.
- Does it contain anything from the exclusion list or raw untrusted input? If so, mask, truncate, or remove.
