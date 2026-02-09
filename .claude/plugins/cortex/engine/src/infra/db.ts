/**
 * SQLite database layer for Cortex memory system
 * Pure I/O boundary - all functions perform side effects
 * Schema management, CRUD operations, and FTS5 search
 */

import { Database } from 'bun:sqlite';
import { randomUUID } from 'crypto';
import type {
  Memory,
  Edge,
  ExtractionCheckpoint,
  MemoryScope,
  EdgeRelation,
} from '../core/types.js';
import { createMemory, createEdge, createExtractionCheckpoint } from '../core/types.js';
import { cosineSimilarity } from '../core/similarity.js';

// ============================================================================
// SCHEMA INITIALIZATION
// ============================================================================

const SCHEMA = `
-- Memory table with all domain fields
CREATE TABLE IF NOT EXISTS memories (
  id TEXT PRIMARY KEY,
  content TEXT NOT NULL,
  summary TEXT NOT NULL,
  memory_type TEXT NOT NULL,
  scope TEXT NOT NULL,
  voyage_embedding BLOB,
  local_embedding BLOB,
  confidence REAL NOT NULL,
  priority INTEGER NOT NULL,
  pinned INTEGER NOT NULL DEFAULT 0,
  source_type TEXT NOT NULL,
  source_session TEXT NOT NULL,
  source_context TEXT NOT NULL,
  tags TEXT NOT NULL, -- JSON array
  access_count INTEGER NOT NULL DEFAULT 0,
  last_accessed_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active'
);

-- Edge table with unique constraint per FR-106
CREATE TABLE IF NOT EXISTS edges (
  id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL,
  target_id TEXT NOT NULL,
  relation_type TEXT NOT NULL,
  strength REAL NOT NULL,
  bidirectional INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'active',
  created_at TEXT NOT NULL,
  FOREIGN KEY (source_id) REFERENCES memories(id) ON DELETE CASCADE,
  FOREIGN KEY (target_id) REFERENCES memories(id) ON DELETE CASCADE,
  UNIQUE (source_id, target_id, relation_type)
);

-- Extraction checkpoint table
CREATE TABLE IF NOT EXISTS extraction_checkpoints (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  cursor_position INTEGER NOT NULL,
  extracted_at TEXT NOT NULL
);

-- FTS5 virtual table for keyword search (FR-101)
-- Using standalone FTS table (not external content) for better Bun compatibility
CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
  id UNINDEXED,
  content,
  summary,
  tags
);

-- Triggers to keep FTS5 in sync with memories table
CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
  INSERT INTO memories_fts(id, content, summary, tags)
  VALUES (new.id, new.content, new.summary, new.tags);
END;

CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
  DELETE FROM memories_fts WHERE id = old.id;
END;

CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE ON memories BEGIN
  DELETE FROM memories_fts WHERE id = old.id;
  INSERT INTO memories_fts(id, content, summary, tags)
  VALUES (new.id, new.content, new.summary, new.tags);
END;

-- Index on status for getActiveMemories optimization
CREATE INDEX IF NOT EXISTS idx_memories_status ON memories(status);

-- Index on session_id for checkpoint lookups
CREATE INDEX IF NOT EXISTS idx_checkpoints_session ON extraction_checkpoints(session_id);

-- Indexes on edges for graph traversal
CREATE INDEX IF NOT EXISTS idx_edges_source ON edges(source_id);
CREATE INDEX IF NOT EXISTS idx_edges_target ON edges(target_id);
`;

/**
 * Initialize database schema and enable optimizations
 * I/O: Creates/modifies database file
 */
function initializeSchema(db: Database): void {
  // Enable WAL mode for concurrent access (FR-100)
  db.run('PRAGMA journal_mode = WAL');

  // Enable foreign key constraints
  db.run('PRAGMA foreign_keys = ON');

  // Execute schema creation
  db.exec(SCHEMA);
}

/**
 * Open or create database at specified path with schema initialization
 * I/O: Opens/creates database file
 *
 * @param path - Database file path (or :memory: for in-memory)
 * @returns Database instance with schema initialized
 */
export function openDatabase(path: string): Database {
  const db = new Database(path);
  initializeSchema(db);
  return db;
}

// ============================================================================
// MEMORY CRUD OPERATIONS
// ============================================================================

/**
 * Serialize Float64Array or Float32Array to Buffer for BLOB storage
 */
function serializeEmbedding(arr: Float64Array | Float32Array): Buffer {
  return Buffer.from(arr.buffer.slice(arr.byteOffset, arr.byteOffset + arr.byteLength));
}

/**
 * Deserialize Buffer to Float64Array
 */
function deserializeFloat64Array(buffer: Buffer): Float64Array {
  return new Float64Array(buffer.buffer, buffer.byteOffset, buffer.byteLength / Float64Array.BYTES_PER_ELEMENT);
}

/**
 * Deserialize Buffer to Float32Array
 */
function deserializeFloat32Array(buffer: Buffer): Float32Array {
  return new Float32Array(buffer.buffer, buffer.byteOffset, buffer.byteLength / Float32Array.BYTES_PER_ELEMENT);
}

/**
 * Insert memory into database
 * I/O: Writes to database
 *
 * @param db - Database instance
 * @param memory - Memory to insert (must be valid via createMemory)
 * @returns Generated memory ID
 */
export function insertMemory(db: Database, memory: Memory): string {
  const stmt = db.prepare(`
    INSERT INTO memories (
      id, content, summary, memory_type, scope,
      voyage_embedding, local_embedding,
      confidence, priority, pinned,
      source_type, source_session, source_context,
      tags, access_count, last_accessed_at,
      created_at, updated_at, status
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);

  stmt.run(
    memory.id,
    memory.content,
    memory.summary,
    memory.memory_type,
    memory.scope,
    memory.voyage_embedding ? serializeEmbedding(memory.voyage_embedding) : null,
    memory.local_embedding ? serializeEmbedding(memory.local_embedding) : null,
    memory.confidence,
    memory.priority,
    memory.pinned ? 1 : 0,
    memory.source_type,
    memory.source_session,
    memory.source_context,
    JSON.stringify(memory.tags),
    memory.access_count,
    memory.last_accessed_at,
    memory.created_at,
    memory.updated_at,
    memory.status
  );

  return memory.id;
}

/**
 * Update memory fields
 * I/O: Writes to database
 *
 * @param db - Database instance
 * @param id - Memory ID to update
 * @param fields - Partial memory fields to update
 */
export function updateMemory(db: Database, id: string, fields: Partial<Memory>): void {
  const updates: string[] = [];
  const values: any[] = [];

  // Build dynamic UPDATE statement based on provided fields
  if (fields.content !== undefined) {
    updates.push('content = ?');
    values.push(fields.content);
  }
  if (fields.summary !== undefined) {
    updates.push('summary = ?');
    values.push(fields.summary);
  }
  if (fields.memory_type !== undefined) {
    updates.push('memory_type = ?');
    values.push(fields.memory_type);
  }
  if (fields.scope !== undefined) {
    updates.push('scope = ?');
    values.push(fields.scope);
  }
  if (fields.voyage_embedding !== undefined) {
    updates.push('voyage_embedding = ?');
    values.push(fields.voyage_embedding ? serializeEmbedding(fields.voyage_embedding) : null);
  }
  if (fields.local_embedding !== undefined) {
    updates.push('local_embedding = ?');
    values.push(fields.local_embedding ? serializeEmbedding(fields.local_embedding) : null);
  }
  if (fields.confidence !== undefined) {
    updates.push('confidence = ?');
    values.push(fields.confidence);
  }
  if (fields.priority !== undefined) {
    updates.push('priority = ?');
    values.push(fields.priority);
  }
  if (fields.pinned !== undefined) {
    updates.push('pinned = ?');
    values.push(fields.pinned ? 1 : 0);
  }
  if (fields.tags !== undefined) {
    updates.push('tags = ?');
    values.push(JSON.stringify(fields.tags));
  }
  if (fields.access_count !== undefined) {
    updates.push('access_count = ?');
    values.push(fields.access_count);
  }
  if (fields.last_accessed_at !== undefined) {
    updates.push('last_accessed_at = ?');
    values.push(fields.last_accessed_at);
  }
  if (fields.status !== undefined) {
    updates.push('status = ?');
    values.push(fields.status);
  }

  // Always update updated_at timestamp
  updates.push('updated_at = ?');
  values.push(new Date().toISOString());

  if (updates.length === 1) {
    // Only updated_at changed, nothing to do
    return;
  }

  values.push(id);

  const query = `UPDATE memories SET ${updates.join(', ')} WHERE id = ?`;
  const stmt = db.prepare(query);

  stmt.run(...values);
}

/**
 * Get memory by ID
 * I/O: Reads from database
 *
 * @param db - Database instance
 * @param id - Memory ID
 * @returns Memory or null if not found
 */
export function getMemory(db: Database, id: string): Memory | null {
  const stmt = db.prepare(`
    SELECT * FROM memories WHERE id = ?
  `);

  const row = stmt.get(id) as any;
  if (!row) {
    return null;
  }

  return createMemory({
    id: row.id,
    content: row.content,
    summary: row.summary,
    memory_type: row.memory_type,
    scope: row.scope,
    voyage_embedding: row.voyage_embedding ? deserializeFloat64Array(row.voyage_embedding) : null,
    local_embedding: row.local_embedding ? deserializeFloat32Array(row.local_embedding) : null,
    confidence: row.confidence,
    priority: row.priority,
    pinned: row.pinned === 1,
    source_type: row.source_type,
    source_session: row.source_session,
    source_context: row.source_context,
    tags: JSON.parse(row.tags),
    access_count: row.access_count,
    last_accessed_at: row.last_accessed_at,
    created_at: row.created_at,
    updated_at: row.updated_at,
    status: row.status,
  });
}

/**
 * Get all active memories (status='active')
 * I/O: Reads from database
 *
 * @param db - Database instance
 * @returns Readonly array of active memories
 */
export function getActiveMemories(db: Database): readonly Memory[] {
  const stmt = db.prepare(`
    SELECT * FROM memories WHERE status = 'active'
  `);

  const rows = stmt.all() as any[];

  return rows.map(row => createMemory({
    id: row.id,
    content: row.content,
    summary: row.summary,
    memory_type: row.memory_type,
    scope: row.scope,
    voyage_embedding: row.voyage_embedding ? deserializeFloat64Array(row.voyage_embedding) : null,
    local_embedding: row.local_embedding ? deserializeFloat32Array(row.local_embedding) : null,
    confidence: row.confidence,
    priority: row.priority,
    pinned: row.pinned === 1,
    source_type: row.source_type,
    source_session: row.source_session,
    source_context: row.source_context,
    tags: JSON.parse(row.tags),
    access_count: row.access_count,
    last_accessed_at: row.last_accessed_at,
    created_at: row.created_at,
    updated_at: row.updated_at,
    status: row.status,
  }));
}

/**
 * Search memories by embedding similarity
 * I/O: Reads from database, performs in-memory similarity computation
 *
 * @param db - Database instance
 * @param embedding - Query embedding (voyage or local)
 * @param limit - Maximum number of results
 * @returns Readonly array of memories sorted by similarity (descending)
 */
export function searchByEmbedding(
  db: Database,
  embedding: Float64Array | Float32Array,
  limit: number
): readonly Memory[] {
  // Determine if query is voyage (Float64) or local (Float32)
  const isVoyage = embedding instanceof Float64Array;

  // Load all memories with embeddings of matching type
  const column = isVoyage ? 'voyage_embedding' : 'local_embedding';
  const stmt = db.prepare(`
    SELECT * FROM memories WHERE ${column} IS NOT NULL
  `);

  const rows = stmt.all() as any[];

  // Compute similarity scores in-memory
  const results = rows.map(row => {
    const memory = createMemory({
      id: row.id,
      content: row.content,
      summary: row.summary,
      memory_type: row.memory_type,
      scope: row.scope,
      voyage_embedding: row.voyage_embedding ? deserializeFloat64Array(row.voyage_embedding) : null,
      local_embedding: row.local_embedding ? deserializeFloat32Array(row.local_embedding) : null,
      confidence: row.confidence,
      priority: row.priority,
      pinned: row.pinned === 1,
      source_type: row.source_type,
      source_session: row.source_session,
      source_context: row.source_context,
      tags: JSON.parse(row.tags),
      access_count: row.access_count,
      last_accessed_at: row.last_accessed_at,
      created_at: row.created_at,
      updated_at: row.updated_at,
      status: row.status,
    });

    const memoryEmbedding = isVoyage ? memory.voyage_embedding : memory.local_embedding;
    if (!memoryEmbedding) {
      throw new Error(`Missing ${column} for memory ${memory.id}`);
    }

    const score = cosineSimilarity(embedding, memoryEmbedding);

    return { memory, score };
  });

  // Sort by score descending and return top N
  return results
    .sort((a, b) => b.score - a.score)
    .slice(0, limit)
    .map(r => r.memory);
}

/**
 * Search memories by keyword using FTS5
 * I/O: Reads from database
 *
 * @param db - Database instance
 * @param query - Keyword search query (FTS5 syntax)
 * @param limit - Maximum number of results
 * @returns Readonly array of memories ranked by FTS5 relevance
 */
export function searchByKeyword(
  db: Database,
  query: string,
  limit: number
): readonly Memory[] {
  const stmt = db.prepare(`
    SELECT m.*
    FROM memories m
    JOIN memories_fts fts ON m.id = fts.id
    WHERE memories_fts MATCH ?
    ORDER BY rank
    LIMIT ?
  `);

  const rows = stmt.all(query, limit) as any[];

  return rows.map(row => createMemory({
    id: row.id,
    content: row.content,
    summary: row.summary,
    memory_type: row.memory_type,
    scope: row.scope,
    voyage_embedding: row.voyage_embedding ? deserializeFloat64Array(row.voyage_embedding) : null,
    local_embedding: row.local_embedding ? deserializeFloat32Array(row.local_embedding) : null,
    confidence: row.confidence,
    priority: row.priority,
    pinned: row.pinned === 1,
    source_type: row.source_type,
    source_session: row.source_session,
    source_context: row.source_context,
    tags: JSON.parse(row.tags),
    access_count: row.access_count,
    last_accessed_at: row.last_accessed_at,
    created_at: row.created_at,
    updated_at: row.updated_at,
    status: row.status,
  }));
}

// ============================================================================
// EDGE CRUD OPERATIONS
// ============================================================================

/**
 * Insert edge into database
 * I/O: Writes to database
 *
 * @param db - Database instance
 * @param edge - Edge to insert (without id and created_at)
 * @returns Generated edge ID
 * @throws If unique constraint violated (duplicate edge)
 */
export function insertEdge(
  db: Database,
  edge: Omit<Edge, 'id' | 'created_at'>
): string {
  const id = randomUUID();
  const created_at = new Date().toISOString();

  const validated = createEdge({
    id,
    source_id: edge.source_id,
    target_id: edge.target_id,
    relation_type: edge.relation_type,
    strength: edge.strength,
    bidirectional: edge.bidirectional,
    status: edge.status,
    created_at,
  });

  const stmt = db.prepare(`
    INSERT INTO edges (id, source_id, target_id, relation_type, strength, bidirectional, status, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `);

  stmt.run(
    validated.id,
    validated.source_id,
    validated.target_id,
    validated.relation_type,
    validated.strength,
    validated.bidirectional ? 1 : 0,
    validated.status,
    validated.created_at
  );

  return validated.id;
}

/**
 * Get all edges for a memory (both outgoing and incoming if bidirectional)
 * I/O: Reads from database
 *
 * @param db - Database instance
 * @param memoryId - Memory ID
 * @returns Readonly array of edges
 */
export function getEdgesForMemory(db: Database, memoryId: string): readonly Edge[] {
  const stmt = db.prepare(`
    SELECT * FROM edges
    WHERE source_id = ? OR (target_id = ? AND bidirectional = 1)
  `);

  const rows = stmt.all(memoryId, memoryId) as any[];

  return rows.map(row => createEdge({
    id: row.id,
    source_id: row.source_id,
    target_id: row.target_id,
    relation_type: row.relation_type as EdgeRelation,
    strength: row.strength,
    bidirectional: row.bidirectional === 1,
    status: row.status,
    created_at: row.created_at,
  }));
}

/**
 * Get all edges in database
 * I/O: Reads from database
 *
 * @param db - Database instance
 * @returns Readonly array of all edges
 */
export function getAllEdges(db: Database): readonly Edge[] {
  const stmt = db.prepare(`SELECT * FROM edges`);
  const rows = stmt.all() as any[];

  return rows.map(row => createEdge({
    id: row.id,
    source_id: row.source_id,
    target_id: row.target_id,
    relation_type: row.relation_type as EdgeRelation,
    strength: row.strength,
    bidirectional: row.bidirectional === 1,
    status: row.status,
    created_at: row.created_at,
  }));
}

// ============================================================================
// EXTRACTION CHECKPOINT OPERATIONS
// ============================================================================

/**
 * Get extraction checkpoint for session
 * I/O: Reads from database
 *
 * @param db - Database instance
 * @param sessionId - Session ID
 * @returns Checkpoint or null if not found
 */
export function getExtractionCheckpoint(
  db: Database,
  sessionId: string
): ExtractionCheckpoint | null {
  const stmt = db.prepare(`
    SELECT * FROM extraction_checkpoints WHERE session_id = ?
  `);

  const row = stmt.get(sessionId) as any;
  if (!row) {
    return null;
  }

  return createExtractionCheckpoint({
    id: row.id,
    session_id: row.session_id,
    cursor_position: row.cursor_position,
    extracted_at: row.extracted_at,
  });
}

/**
 * Save or update extraction checkpoint
 * I/O: Writes to database
 *
 * @param db - Database instance
 * @param checkpoint - Checkpoint to save (without id)
 */
export function saveExtractionCheckpoint(
  db: Database,
  checkpoint: Omit<ExtractionCheckpoint, 'id'>
): void {
  const extracted_at = new Date().toISOString();

  // Check if checkpoint exists for this session
  const existing = getExtractionCheckpoint(db, checkpoint.session_id);

  if (existing) {
    // Update existing checkpoint
    const stmt = db.prepare(`
      UPDATE extraction_checkpoints
      SET cursor_position = ?, extracted_at = ?
      WHERE session_id = ?
    `);

    stmt.run(checkpoint.cursor_position, extracted_at, checkpoint.session_id);
  } else {
    // Insert new checkpoint
    const id = randomUUID();
    const validated = createExtractionCheckpoint({
      id,
      session_id: checkpoint.session_id,
      cursor_position: checkpoint.cursor_position,
      extracted_at,
    });

    const stmt = db.prepare(`
      INSERT INTO extraction_checkpoints (id, session_id, cursor_position, extracted_at)
      VALUES (?, ?, ?, ?)
    `);

    stmt.run(
      validated.id,
      validated.session_id,
      validated.cursor_position,
      validated.extracted_at
    );
  }
}

// ============================================================================
// CHECKPOINT/RESTORE FOR CONSOLIDATION SAFETY
// ============================================================================

/**
 * Create database checkpoint (backup)
 * I/O: Creates backup file using VACUUM INTO
 *
 * @param db - Database instance
 * @returns Path to checkpoint file
 */
export function createCheckpoint(db: Database): string {
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  const checkpointPath = `${db.filename}.checkpoint-${timestamp}`;

  // Use VACUUM INTO to create a backup
  db.run(`VACUUM INTO '${checkpointPath}'`);

  return checkpointPath;
}

/**
 * Restore database from checkpoint
 * I/O: Overwrites current database with checkpoint
 *
 * Note: This requires closing the current database and copying the checkpoint.
 * In production, this would need to be handled at a higher level.
 *
 * @param db - Database instance
 * @param checkpointPath - Path to checkpoint file
 */
export function restoreCheckpoint(db: Database, checkpointPath: string): void {
  // Attach the checkpoint database and copy all data
  db.run(`ATTACH DATABASE '${checkpointPath}' AS checkpoint`);

  // Get all regular table names from checkpoint (exclude FTS tables)
  const tables = db.query(`
    SELECT name FROM checkpoint.sqlite_master
    WHERE type='table'
      AND name NOT LIKE 'sqlite_%'
      AND name NOT LIKE '%_fts%'
  `).all() as { name: string }[];

  // Clear current tables and copy from checkpoint
  for (const { name } of tables) {
    db.run(`DELETE FROM main.${name}`);
    db.run(`INSERT INTO main.${name} SELECT * FROM checkpoint.${name}`);
  }

  db.run('DETACH DATABASE checkpoint');
}

// ============================================================================
// SCOPE ROUTING
// ============================================================================

/**
 * Route to appropriate database based on memory scope
 * I/O: Opens database if not already open
 *
 * @param scope - Memory scope (project or global)
 * @param projectDbPath - Path to project database
 * @param globalDbPath - Path to global database
 * @returns Database instance for the scope
 */
export function routeToDatabase(
  scope: MemoryScope,
  projectDbPath: string,
  globalDbPath: string
): Database {
  const path = scope === 'project' ? projectDbPath : globalDbPath;
  return openDatabase(path);
}
