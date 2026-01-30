# Domain Primitives with Smart Constructors

## Idea
Move invariant validation from aggregate constructors to domain primitive types with Either-returning smart constructors.

## Pattern (Haskell-inspired)

```java
// Primitive with smart constructor - validates once
public record PositiveInt(int value) {
    public static Either<String, PositiveInt> of(int n) {
        return n > 0 ? Either.right(new PositiveInt(n)) : Either.left("must be positive");
    }
}

// Aggregate composes validated types - no validation needed
public record OrderLine(ProductId productId, PositiveInt quantity, Money price) {}
```

## Benefits
- Validation happens once at boundary (parse, don't validate)
- Aggregates trivially constructible from validated parts
- No Either verbosity explosion in every record
- Type system enforces invariants

## Organization Options

**Generic primitives shared:**
```
domain/primitives/  # PositiveInt, NonEmptyString, Email
domain/order/       # Order, OrderLine (uses primitives)
```

**Domain-specific co-located:**
```
domain/order/
  Quantity.java     # PositiveInt named for domain context
  OrderLine.java
```

**Hybrid:** generic shared, domain-specific co-located.

## Full Java Examples

### Generic Primitives

```java
// domain/primitives/PositiveInt.java
public record PositiveInt(int value) {
    private PositiveInt {}

    public static Either<String, PositiveInt> of(int n) {
        return n > 0
            ? Either.right(new PositiveInt(n))
            : Either.left("must be positive, got: " + n);
    }
}

// domain/primitives/NonEmptyString.java
public record NonEmptyString(String value) {
    private NonEmptyString {}

    public static Either<String, NonEmptyString> of(String s) {
        return s != null && !s.isBlank()
            ? Either.right(new NonEmptyString(s.trim()))
            : Either.left("must not be empty");
    }
}

// domain/primitives/Email.java
public record Email(String value) {
    private static final Pattern EMAIL_PATTERN = Pattern.compile("^[^@]+@[^@]+\\.[^@]+$");
    private Email {}

    public static Either<String, Email> of(String s) {
        if (s == null || !EMAIL_PATTERN.matcher(s).matches()) {
            return Either.left("invalid email: " + s);
        }
        return Either.right(new Email(s.toLowerCase().trim()));
    }
}
```

### Domain-Specific Primitives

```java
// domain/order/Quantity.java
public record Quantity(int value) {
    private Quantity {}

    public static Either<String, Quantity> of(int n) {
        if (n <= 0) return Either.left("quantity must be positive");
        if (n > 10000) return Either.left("quantity exceeds max (10000)");
        return Either.right(new Quantity(n));
    }

    public Quantity add(Quantity other) {
        // Already validated, can construct directly internally
        return new Quantity(this.value + other.value);
    }
}

// domain/customer/CustomerId.java
public record CustomerId(String value) {
    private CustomerId {}

    public static Either<String, CustomerId> of(String s) {
        if (s == null || !s.startsWith("CUS-")) {
            return Either.left("customer id must start with CUS-");
        }
        return Either.right(new CustomerId(s));
    }
}
```

### Aggregates Using Validated Primitives

```java
// domain/order/OrderLine.java
// No validation needed - fields are already validated types
public record OrderLine(ProductId productId, Quantity quantity, Money price) {
    public Money total() {
        return price.multiply(quantity.value());
    }
}

// domain/order/Order.java
public record Order(
    OrderId id,
    CustomerId customer,
    List<OrderLine> lines,
    Instant createdAt
) {
    public Order {
        lines = List.copyOf(lines); // defensive copy only
    }

    public Money total() {
        return lines.stream()
            .map(OrderLine::total)
            .reduce(Money.ZERO, Money::add);
    }
}
```

### Parsing at the Boundary

```java
// application/OrderRequestParser.java
public class OrderRequestParser {

    public Either<String, Order> parse(OrderRequest req) {
        return Eithers.combine(
            OrderId.generate(),
            CustomerId.of(req.customerId()),
            parseLines(req.lines())
        ).map((orderId, customerId, lines) ->
            new Order(orderId, customerId, lines, Instant.now())
        );
    }

    private Either<String, List<OrderLine>> parseLines(List<LineRequest> reqs) {
        return Eithers.traverse(reqs, this::parseLine);
    }

    private Either<String, OrderLine> parseLine(LineRequest req) {
        return Eithers.combine(
            ProductId.of(req.productId()),
            Quantity.of(req.quantity()),
            Money.of(req.price())
        ).map(OrderLine::new);
    }
}
```

### Controller (Imperative Shell)

```java
@RestController
public class OrderController {
    private final OrderRequestParser parser;
    private final OrderService service;

    @PostMapping("/orders")
    public ResponseEntity<?> createOrder(@RequestBody OrderRequest req) {
        return parser.parse(req)
            .flatMap(service::process)
            .fold(
                error -> ResponseEntity.badRequest().body(error),
                order -> ResponseEntity.ok(order)
            );
    }
}
```

## Status
Parked - significant refactor. Current approach: throwing in constructors is acceptable.
