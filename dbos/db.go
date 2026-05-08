package dbos

import (
	"context"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Dialect identifies the SQL dialect of the system database backend. It is
// used to gate dialect-specific migrations and runtime behavior (LISTEN/NOTIFY
// vs. polling, dequeue locking strategy, etc.).
type Dialect string

const (
	DialectPostgres  Dialect = "postgres"
	DialectCockroach Dialect = "cockroach"
	DialectSQLite    Dialect = "sqlite"
)

// Transaction is the database-agnostic abstraction for a single transaction.
// pgx.Tx satisfies this interface, and a future SQLite backend can provide its
// own implementation. The row and result types are aliased to pgx for now;
// alternative backends will need to provide adapter types.
type Transaction interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Commit(ctx context.Context) error
	Rollback(ctx context.Context) error
}

// IsolationLevel is the database-agnostic isolation level for a transaction.
type IsolationLevel string

const (
	IsolationReadUncommitted IsolationLevel = "read uncommitted"
	IsolationReadCommitted   IsolationLevel = "read committed"
	IsolationRepeatableRead  IsolationLevel = "repeatable read"
	IsolationSerializable    IsolationLevel = "serializable"
)

// TxOptions configures a new transaction in a backend-agnostic way.
type TxOptions struct {
	IsolationLevel IsolationLevel
}

// DB is the database-agnostic abstraction for a connection pool able to begin
// transactions and execute statements directly. The pgxDB wrapper below adapts
// pgxpool.Pool to satisfy this interface.
type DB interface {
	Begin(ctx context.Context) (Transaction, error)
	BeginTx(ctx context.Context, opts TxOptions) (Transaction, error)
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Ping(ctx context.Context) error
	Close()
}

// pgxDB adapts a *pgxpool.Pool to the DB interface. It exists so the rest of
// the system_database layer can be expressed in terms of the abstract DB,
// while pgx-specific paths (LISTEN/NOTIFY, Acquire) keep direct pool access.
type pgxDB struct {
	pool *pgxpool.Pool
}

func newPgxDB(pool *pgxpool.Pool) *pgxDB { return &pgxDB{pool: pool} }

func (p *pgxDB) Begin(ctx context.Context) (Transaction, error) {
	return p.pool.Begin(ctx)
}

func (p *pgxDB) BeginTx(ctx context.Context, opts TxOptions) (Transaction, error) {
	return p.pool.BeginTx(ctx, toPgxTxOptions(opts))
}

func (p *pgxDB) Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error) {
	return p.pool.Exec(ctx, sql, args...)
}

func (p *pgxDB) Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error) {
	return p.pool.Query(ctx, sql, args...)
}

func (p *pgxDB) QueryRow(ctx context.Context, sql string, args ...any) pgx.Row {
	return p.pool.QueryRow(ctx, sql, args...)
}

func (p *pgxDB) Ping(ctx context.Context) error { return p.pool.Ping(ctx) }
func (p *pgxDB) Close()                         { p.pool.Close() }

func toPgxTxOptions(opts TxOptions) pgx.TxOptions {
	out := pgx.TxOptions{}
	switch opts.IsolationLevel {
	case "":
		// leave default
	case IsolationReadUncommitted:
		out.IsoLevel = pgx.ReadUncommitted
	case IsolationReadCommitted:
		out.IsoLevel = pgx.ReadCommitted
	case IsolationRepeatableRead:
		out.IsoLevel = pgx.RepeatableRead
	case IsolationSerializable:
		out.IsoLevel = pgx.Serializable
	}
	return out
}
