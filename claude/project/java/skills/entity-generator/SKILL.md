---
name: entity-generator
description: "Generate JPA entity classes from Oracle CREATE TABLE DDL statements. Use when the user provides a CREATE TABLE definition and wants a Hibernate entity. Handles Oracle types (VARCHAR2, NUMBER, CLOB, CHAR, DATE, TIMESTAMP, BLOB), schema-qualified tables, and follows the hibertable11 repo conventions."
user_invocable: true
---

# Entity Generator Skill

Generate JPA entity classes from Oracle `CREATE TABLE` DDL following hibertable11 conventions.

## Input

User provides a `CREATE TABLE` statement. Example:

```sql
CREATE TABLE RATOR.WF_ACTION_CONFIG
(
  UUID           CHAR(36 CHAR)                  NOT NULL,
  ACTION         VARCHAR2(256 CHAR),
  CONFIG         CLOB,
  CONFIG_FORMAT  VARCHAR2(256 CHAR),
  ID             NUMBER
)
```

## Generation Rules

### 1. Package Placement

Determine package from table name prefix or schema:
- Table starts with `OI_` → `dk.secondbrand.hibertable11.domain.entity.oister`, class prefixed `Oi`
- Table starts with `FLEXII_` → `dk.secondbrand.hibertable11.domain.entity.flexii`, class prefixed `Flexii`
- Otherwise → `dk.secondbrand.hibertable11.domain.entity.shared`

If the table name has a known prefix like `WF_`, `DK2_`, `GENERIC_` — keep it in `shared` unless user specifies.

**Ask the user** if placement is ambiguous.

### 2. Class Name Derivation

Convert `UPPER_SNAKE_CASE` table name to `PascalCase`:
- Remove schema prefix (e.g., `RATOR.`)
- Remove brand prefix (`OI_`, `FLEXII_`) — it becomes the class prefix
- `WF_ACTION_CONFIG` → `WfActionConfig`
- `OI_ACCOUNT` → `OiAccount`
- `FLEXII_USER` → `FlexiiUser`
- `PROVISIONING_LOG` → `ProvisioningLog`

### 3. Class Structure (exact annotation order)

```java
package dk.secondbrand.hibertable11.domain.entity.<subpackage>;

import dk.secondbrand.hibertable11.utils.NextOidGenerator;
import jakarta.persistence.*;
import lombok.*;

// Add java.time imports only if date/timestamp columns exist
// Add java.math.BigDecimal only if NUMBER with scale > 0

@Entity
@Table(name = "TABLE_NAME")              // Add schema = "SCHEMA" if schema-qualified
@Getter
@Setter
@ToString                                 // Add exclude = {"field"} for @Lob and relationship fields
@NoArgsConstructor
@AllArgsConstructor
public class ClassName {

    @Id
    @NextOidGenerator
    @Column(name = "ID", nullable = false)
    private Long id;

    // ... fields ...
}
```

### 4. Oracle → Java Type Mapping

| Oracle Type | Java Type | @Column Attributes |
|---|---|---|
| `NUMBER` (no precision) | `Long` | — |
| `NUMBER(p)` where p ≤ 9 | `Integer` | — |
| `NUMBER(p)` where p > 9, scale=0 | `Long` | — |
| `NUMBER(p,s)` where s > 0 | `BigDecimal` | `precision = p, scale = s` |
| `VARCHAR2(n CHAR)` or `VARCHAR2(n)` | `String` | `length = n` |
| `CHAR(n CHAR)` or `CHAR(n)` | `String` | `length = n` |
| `CLOB` | `String` | Add `@Lob` on separate line above `@Column` |
| `BLOB` | `byte[]` | Add `@Lob` + `@Basic(fetch = FetchType.LAZY)` |
| `DATE` | `LocalDateTime` | — |
| `TIMESTAMP` | `LocalDateTime` | — |
| `TIMESTAMP WITH TIME ZONE` | `LocalDateTime` | — |
| `RAW(16)` | `String` | `length = 32` (hex representation) |

### 5. Field Name Derivation

Convert `UPPER_SNAKE_CASE` column name to `camelCase`:
- `STATUS_ID` → `statusId`
- `CREATE_DATE` → `createDate`
- `UUID` → `uuid`
- `CONFIG_FORMAT` → `configFormat`

### 6. ID Column Handling

- If table has an `ID NUMBER` column → standard `@Id @NextOidGenerator @Column(name = "ID", nullable = false) private Long id;`
- If table has NO `ID` column but has a `UUID CHAR(36)` → use UUID as primary key:
  ```java
  @Id
  @Column(name = "UUID", length = 36, nullable = false)
  private String uuid;
  ```
  (No `@NextOidGenerator` — UUID is externally assigned)
- If table has BOTH `ID` and `UUID` → `ID` is the `@Id` with `@NextOidGenerator`, `UUID` is a regular field

### 7. NOT NULL Handling

- If column is `NOT NULL` → add `nullable = false` to `@Column`
- Exception: `ID` column already has `nullable = false` by convention

### 8. Schema Handling

If table is schema-qualified (e.g., `RATOR.TABLE_NAME`):
```java
@Table(name = "TABLE_NAME", schema = "RATOR")
```

### 9. @Lob Fields

For CLOB/BLOB columns:
```java
@Lob
@Column(name = "CONFIG")
private String config;
```

Add the field name to `@ToString(exclude = {"config"})` to avoid lazy-load issues.

### 10. Relationship Resolution for FK Columns

For every column ending in `_ID` that is NOT the primary key, **you MUST search the existing codebase** to check if a matching entity already exists.

**Lookup procedure:**
1. Take the column name, strip the `_ID` suffix → candidate table name (e.g., `WORKFLOW_ID` → `WORKFLOW`)
2. Also try with common prefixes: `OI_`, `FLEXII_`, `WF_`, `GENERIC_` (e.g., `WF_WORKFLOW`)
3. Search for existing entities: use Grep/Glob to find `@Table(name = "WORKFLOW"` or `@Table(name = "WF_WORKFLOW"` etc. across `src/main/java/**/entity/**/*.java`
4. Also check if the column name itself matches a known table (e.g., `PROVISIONING_TASK_ID` → look for table `PROVISIONING_TASK`)

**If a matching entity IS found:**
Generate the full relationship following repo conventions — raw FK Long + read-only `@ManyToOne`:
```java
@Column(name = "WORKFLOW_ID")
private Long workflowId;

@ManyToOne(fetch = FetchType.LAZY)
@JoinColumn(name = "WORKFLOW_ID", insertable = false, updatable = false)
private Workflow workflow;
```
- Add the relationship field name to `@ToString(exclude = {...})` to avoid lazy-load issues
- Import the entity class if it's in a different package

**If NO matching entity is found:**
Leave a commented-out relationship hint:
```java
@Column(name = "WORKFLOW_ID")
private Long workflowId;

// TODO: Add relationship if entity exists
// @ManyToOne(fetch = FetchType.LAZY)
// @JoinColumn(name = "WORKFLOW_ID", insertable = false, updatable = false)
// private Workflow workflow;
```

**Special cases:**
- `STATUS_ID` → check for `Status` entity (table `STATUS` or `STATUS_TYPES`)
- `BRAND_ID` → typically no entity, leave as raw Long with no TODO
- Column name matches table in DDL being processed (self-referential) → use same class

### 11. Import Rules

Only import what's needed:
- Always: `jakarta.persistence.*`, `lombok.*`, `NextOidGenerator` (if ID column uses it)
- Conditionally: `java.time.LocalDateTime` (date/timestamp cols), `java.math.BigDecimal` (decimal cols)

### 12. File Output Location

Write entity to: `src/main/java/dk/secondbrand/hibertable11/domain/entity/<subpackage>/<ClassName>.java`

## Example Output

Given:
```sql
CREATE TABLE RATOR.WF_ACTION_CONFIG
(
  UUID           CHAR(36 CHAR)                  NOT NULL,
  ACTION         VARCHAR2(256 CHAR),
  CONFIG         CLOB,
  CONFIG_FORMAT  VARCHAR2(256 CHAR),
  ID             NUMBER
)
```

Produces:
```java
package dk.secondbrand.hibertable11.domain.entity.shared;

import dk.secondbrand.hibertable11.utils.NextOidGenerator;
import jakarta.persistence.*;
import lombok.*;

@Entity
@Table(name = "WF_ACTION_CONFIG", schema = "RATOR")
@Getter
@Setter
@ToString(exclude = {"config"})
@NoArgsConstructor
@AllArgsConstructor
public class WfActionConfig {

    @Id
    @NextOidGenerator
    @Column(name = "ID", nullable = false)
    private Long id;

    @Column(name = "UUID", length = 36, nullable = false)
    private String uuid;

    @Column(name = "ACTION", length = 256)
    private String action;

    @Lob
    @Column(name = "CONFIG")
    private String config;

    @Column(name = "CONFIG_FORMAT", length = 256)
    private String configFormat;
}
```

## Field Ordering

1. `@Id` field always first
2. Then remaining fields in the order they appear in the CREATE TABLE (excluding ID which was moved to top)

## Multiple Tables

If user provides multiple CREATE TABLE statements, generate one entity per table. Ask about shared base classes if tables have identical column subsets.

## Inheritance Detection

If two tables (e.g., `OI_MAIL_MESSAGE` and `FLEXII_MAIL_MESSAGE`) share most columns:
- Suggest a `@MappedSuperclass` base in `shared/`
- Concrete entities in `oister/` and `flexii/` extending it
- Use `@SuperBuilder` + `@NoArgsConstructor` instead of `@AllArgsConstructor`
