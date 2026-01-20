---
name: test-engineer
description: "Expert guidance for Java/Spring Boot testing. Use when writing unit tests (JUnit 5, Mockito), integration tests (Spring Boot Test), property-based tests (jqwik), or fixing/reviewing test suites. Covers TDD, test patterns, mocking strategies, security testing, and test anti-patterns. Triggers on: writing tests, test failures, improving test coverage, property-based testing, mocking questions, test architecture decisions."
---

# Test Engineer Skill - Java/Spring Boot

Expert guidance for writing, reviewing, and fixing tests in Java/Spring Boot applications.

## Core Principles

### 1. Test Pyramid Strategy
- **Unit tests** (70%): Fast, isolated, no Spring context
- **Integration tests** (20%): Spring context, real dependencies where practical
- **E2E tests** (10%): Full system, use sparingly

### 2. Testability Over Mocking
Design code to be testable rather than relying on heavy mocking:
- Prefer constructor injection over field injection
- Extract pure functions from side-effectful code
- Use interfaces at boundaries, concrete classes internally
- Small, focused classes with single responsibility

### 3. Test Behavior, Not Implementation
- Test public API, not internal methods
- Avoid testing private methods directly
- Tests should survive refactoring if behavior unchanged

### 4. Property Tests > Example Tests (When Applicable)
Prefer property-based tests over example-based tests when:
- Testing pure functions with clear invariants
- Validating parsers, serializers, converters (round-trip)
- Business rules with mathematical properties
- Input validation with large input spaces

---

## Property-Based Testing (jqwik) - PREFERRED APPROACH

Property tests find edge cases you'd never think to write. Use them for any pure function or stateless logic.

### When to Use Property Tests
| Use Property Tests | Use Example Tests |
|-------------------|-------------------|
| Pure functions | Side effects (DB, HTTP) |
| Validation logic | Specific business scenarios |
| Parsers/serializers | Integration flows |
| Mathematical properties | UI interactions |
| Large input spaces | Small, enumerable cases |

### Maven Dependency
```xml
<dependency>
    <groupId>net.jqwik</groupId>
    <artifactId>jqwik</artifactId>
    <version>1.8.2</version>
    <scope>test</scope>
</dependency>
```

### Common Property Patterns

#### 1. Invariants - "This should always be true"
```java
@Property
void priceShouldNeverBeNegative(@ForAll @Positive int qty,
                                 @ForAll @Positive int unitPrice,
                                 @ForAll @IntRange(min = 0, max = 100) int discount) {
    var total = calculator.calculate(qty, unitPrice, discount);
    assertThat(total).isGreaterThanOrEqualTo(0);
}

@Property
void cprShouldAlwaysHave10Digits(@ForAll("validCprs") String cpr) {
    assertThat(cpr.replaceAll("-", "")).hasSize(10);
}
```

#### 2. Round-Trip / Symmetry - "Encode then decode = original"
```java
@Property
void serializeDeserializeShouldBeIdentity(@ForAll("users") User user) {
    var json = mapper.writeValueAsString(user);
    var restored = mapper.readValue(json, User.class);
    assertThat(restored).isEqualTo(user);
}

@Property
void encryptDecryptShouldBeIdentity(@ForAll String plaintext,
                                     @ForAll("keys") SecretKey key) {
    var encrypted = crypto.encrypt(plaintext, key);
    var decrypted = crypto.decrypt(encrypted, key);
    assertThat(decrypted).isEqualTo(plaintext);
}
```

#### 3. Idempotence - "Doing it twice = doing it once"
```java
@Property
void normalizeShouldBeIdempotent(@ForAll String input) {
    var once = normalizer.normalize(input);
    var twice = normalizer.normalize(once);
    assertThat(twice).isEqualTo(once);
}

@Property
void sortingTwiceShouldNotChange(@ForAll List<Integer> list) {
    var sorted = sort(list);
    var sortedAgain = sort(sorted);
    assertThat(sortedAgain).isEqualTo(sorted);
}
```

#### 4. Commutativity - "Order doesn't matter"
```java
@Property
void additionShouldBeCommutative(@ForAll int a, @ForAll int b) {
    assertThat(calculator.add(a, b)).isEqualTo(calculator.add(b, a));
}
```

#### 5. Test Oracle - "Compare with known-good implementation"
```java
@Property
void customSortShouldMatchJavaSort(@ForAll List<Integer> list) {
    var expected = new ArrayList<>(list);
    Collections.sort(expected);

    var actual = customSort.sort(list);
    assertThat(actual).isEqualTo(expected);
}
```

#### 6. Metamorphic - "Related inputs should have related outputs"
```java
@Property
void doublingInputShouldDoubleOutput(@ForAll @Positive int qty,
                                      @ForAll @Positive int price) {
    var single = calculator.total(qty, price);
    var doubled = calculator.total(qty * 2, price);
    assertThat(doubled).isEqualTo(single * 2);
}
```

### Custom Arbitraries

#### Domain-Specific Generators
```java
@Provide
Arbitrary<String> validCprs() {
    return Arbitraries.integers().between(1, 31).flatMap(day ->
        Arbitraries.integers().between(1, 12).flatMap(month ->
            Arbitraries.integers().between(0, 99).flatMap(year ->
                Arbitraries.integers().between(0, 9999).map(seq ->
                    String.format("%02d%02d%02d-%04d", day, month, year, seq)
                ))));
}

@Provide
Arbitrary<PhoneNumber> danishPhoneNumbers() {
    return Arbitraries.integers().between(10000000, 99999999)
        .map(n -> new PhoneNumber("+45", String.valueOf(n)));
}

@Provide
Arbitrary<Email> validEmails() {
    var locals = Arbitraries.strings().alpha().ofMinLength(1).ofMaxLength(20);
    var domains = Arbitraries.of("gmail.com", "outlook.com", "company.dk");
    return Combinators.combine(locals, domains)
        .as((local, domain) -> new Email(local + "@" + domain));
}
```

#### Combining Arbitraries
```java
@Provide
Arbitrary<Order> orders() {
    return Combinators.combine(
        Arbitraries.longs().greaterOrEqual(1),
        orderStatuses(),
        Arbitraries.lists(orderItems()).ofMinSize(1).ofMaxSize(10),
        Arbitraries.of(Currency.DKK, Currency.EUR)
    ).as(Order::new);
}

@Provide
Arbitrary<OrderStatus> orderStatuses() {
    return Arbitraries.of(OrderStatus.class);
}
```

### Constraining Generation

```java
@Property
void shouldHandleValidAges(@ForAll @IntRange(min = 0, max = 150) int age) {
    assertThat(validator.isValidAge(age)).isTrue();
}

@Property
void shouldRejectEmptyStrings(@ForAll @NotEmpty String input) {
    // input will never be empty
}

@Property
void shouldWorkWithUniqueItems(@ForAll @UniqueElements List<String> items) {
    // items has no duplicates
}

@Property
void shouldHandleSmallLists(@ForAll @Size(max = 5) List<Integer> list) {
    // list has at most 5 elements
}
```

### Statistics and Reporting

```java
@Property
void shouldDistributeEvenly(@ForAll @IntRange(min = 1, max = 100) int value) {
    Statistics.label("range")
        .collect(value <= 25 ? "1-25" :
                 value <= 50 ? "26-50" :
                 value <= 75 ? "51-75" : "76-100");

    // actual test
    assertThat(process(value)).isNotNull();
}
```

### Shrinking - Finding Minimal Failing Case
jqwik automatically shrinks failing cases to the simplest reproduction:
```java
@Property
void listShouldNotExceedMax(@ForAll List<Integer> list) {
    assertThat(list.size()).isLessThan(100);
    // If fails with 150-item list, jqwik shrinks to exactly 100 items
}
```

### Combining with JUnit 5

```java
class UserValidatorTest {
    // Example-based for specific business cases
    @Test
    void shouldRejectKnownInvalidCpr_1234567890() {
        assertThat(validator.isValid("123456-7890")).isFalse();
    }

    // Property-based for general invariants
    @Property
    void shouldAcceptAllValidCprFormats(@ForAll("validCprs") String cpr) {
        assertThat(validator.isValid(cpr)).isTrue();
    }

    @Property
    void shouldRejectAllMalformedCprs(@ForAll("malformedCprs") String cpr) {
        assertThat(validator.isValid(cpr)).isFalse();
    }
}
```

---

## Unit Testing Patterns

### JUnit 5 Structure
```java
@ExtendWith(MockitoExtension.class)
class ServiceTest {
    @Mock Repository repo;
    @InjectMocks Service service;

    @Test
    void shouldDoSomething_whenCondition() {
        // given
        var input = createInput();
        when(repo.find(any())).thenReturn(Optional.of(entity));

        // when
        var result = service.process(input);

        // then
        assertThat(result).isEqualTo(expected);
        verify(repo).save(any());
    }
}
```

### Naming Convention
```
methodName_shouldExpectedBehavior_whenCondition
```
Examples:
- `calculateTotal_shouldApplyDiscount_whenCustomerIsPremium`
- `validateCpr_shouldThrowException_whenFormatInvalid`

### AssertJ Over JUnit Assertions
```java
// Prefer
assertThat(result).hasSize(3).contains("a", "b");
assertThat(exception).isInstanceOf(ValidationException.class)
    .hasMessageContaining("invalid");

// Avoid
assertEquals(3, result.size());
assertTrue(result.contains("a"));
```

### Testing Exceptions
```java
@Test
void shouldThrowWhenInvalid() {
    assertThatThrownBy(() -> service.process(null))
        .isInstanceOf(IllegalArgumentException.class)
        .hasMessageContaining("must not be null");
}

// Or with JUnit 5
var ex = assertThrows(ValidationException.class,
    () -> service.validate(input));
assertThat(ex.getErrors()).hasSize(2);
```

### Parameterized Tests
```java
@ParameterizedTest
@CsvSource({
    "100, 10, 90",    // normal discount
    "50, 0, 50",      // no discount
    "200, 25, 150"    // max discount
})
void shouldCalculateDiscount(int price, int discount, int expected) {
    assertThat(calculator.apply(price, discount)).isEqualTo(expected);
}

@ParameterizedTest
@MethodSource("invalidInputs")
void shouldRejectInvalidInput(String input, String expectedError) {
    assertThatThrownBy(() -> validator.validate(input))
        .hasMessageContaining(expectedError);
}

static Stream<Arguments> invalidInputs() {
    return Stream.of(
        Arguments.of(null, "must not be null"),
        Arguments.of("", "must not be empty"),
        Arguments.of("abc", "must be numeric")
    );
}
```

---

## Mocking Best Practices

### When to Mock
- External services (HTTP clients, message queues)
- Time-dependent code (`Clock`)
- Randomness (`Random`, UUID generators)
- Database (only in unit tests)

### When NOT to Mock
- Value objects and DTOs
- Pure functions
- Your own code in integration tests
- Things you can use real instances of

### Mock Injection Patterns
```java
// Constructor injection - preferred
class Service {
    private final Repository repo;
    private final Clock clock;

    Service(Repository repo, Clock clock) {
        this.repo = repo;
        this.clock = clock;
    }
}

// In test
var clock = Clock.fixed(Instant.parse("2024-01-15T10:00:00Z"), ZoneId.UTC);
var service = new Service(mockRepo, clock);
```

### Verify Sparingly
```java
// Good: verify critical interactions
verify(emailService).send(any(Email.class));

// Bad: over-verification couples tests to implementation
verify(repo).findById(1L);
verify(mapper).toDto(any());
verify(validator).validate(any());
// These are implementation details
```

### Argument Captors
```java
@Captor ArgumentCaptor<Email> emailCaptor;

@Test
void shouldSendWelcomeEmail() {
    service.registerUser(user);

    verify(emailService).send(emailCaptor.capture());
    var email = emailCaptor.getValue();
    assertThat(email.getTo()).isEqualTo(user.getEmail());
    assertThat(email.getSubject()).contains("Welcome");
}
```

---

## Spring Boot Integration Tests

### Base Test Configuration
```java
@SpringBootTest
@ActiveProfiles("test")
@Transactional  // rollback after each test
abstract class BaseIntegrationTest {
    @Autowired protected MockMvc mockMvc;
    @MockBean protected ExternalService externalService;
}
```

### Controller Tests with MockMvc
```java
@WebMvcTest(UserController.class)
@Import(TestSecurityConfig.class)
class UserControllerTest {
    @Autowired MockMvc mockMvc;
    @MockBean UserService userService;

    @Test
    void shouldReturnUser() throws Exception {
        when(userService.findById(1L)).thenReturn(Optional.of(user));

        mockMvc.perform(get("/api/users/1")
                .with(jwt().authorities(new SimpleGrantedAuthority("ROLE_USER"))))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.name").value("John"));
    }

    @Test
    void shouldReturn404WhenNotFound() throws Exception {
        when(userService.findById(anyLong())).thenReturn(Optional.empty());

        mockMvc.perform(get("/api/users/999")
                .with(jwt()))
            .andExpect(status().isNotFound());
    }
}
```

### Repository Tests
```java
@DataJpaTest
@AutoConfigureTestDatabase(replace = Replace.NONE)
@Testcontainers
class UserRepositoryTest {
    @Container
    static OracleContainer oracle = new OracleContainer("gvenzl/oracle-xe:21-slim");

    @Autowired UserRepository repo;

    @Test
    void shouldFindByEmail() {
        repo.save(new User("test@example.com"));

        var found = repo.findByEmail("test@example.com");

        assertThat(found).isPresent();
    }
}
```

### Service Integration Tests
```java
@SpringBootTest
@ActiveProfiles("test")
class OrderServiceIntegrationTest extends BaseIntegrationTest {
    @Autowired OrderService orderService;
    @Autowired OrderRepository orderRepo;

    @Test
    void shouldProcessOrder() {
        var order = orderService.create(orderRequest);

        assertThat(order.getStatus()).isEqualTo(PENDING);
        assertThat(orderRepo.findById(order.getId())).isPresent();
    }
}
```

---

## Security Testing

### JWT/OAuth2 Test Patterns
```java
@Test
@WithMockUser(roles = "ADMIN")
void shouldAllowAdminAccess() throws Exception {
    mockMvc.perform(get("/api/admin/users"))
        .andExpect(status().isOk());
}

@Test
void shouldRequireAuthentication() throws Exception {
    mockMvc.perform(get("/api/protected"))
        .andExpect(status().isUnauthorized());
}

// Custom JWT claims
@Test
void shouldExtractRealmRoles() throws Exception {
    mockMvc.perform(get("/api/resource")
            .with(jwt().jwt(jwt -> jwt
                .claim("realm_access", Map.of("roles", List.of("manager", "viewer")))
            )))
        .andExpect(status().isOk());
}
```

### ABAC Policy Testing
```java
@Test
void shouldEnforceAbacPolicy() {
    // given user without required permission
    mockSecurityContext(userWithoutPermission);

    // when/then
    assertThatThrownBy(() -> service.sensitiveOperation())
        .isInstanceOf(AccessDeniedException.class);
}
```

---

## Test Data Builders

### Builder Pattern for Test Data
```java
class UserBuilder {
    private String email = "default@test.com";
    private String name = "Test User";
    private List<Role> roles = List.of(Role.USER);

    static UserBuilder aUser() { return new UserBuilder(); }

    UserBuilder withEmail(String email) { this.email = email; return this; }
    UserBuilder withName(String name) { this.name = name; return this; }
    UserBuilder withRoles(Role... roles) { this.roles = List.of(roles); return this; }
    UserBuilder asAdmin() { return withRoles(Role.ADMIN); }

    User build() { return new User(email, name, roles); }
}

// Usage
var admin = aUser().withEmail("admin@test.com").asAdmin().build();
```

### Mother Pattern for Complex Objects
```java
class OrderMother {
    static Order pendingOrder() {
        return Order.builder()
            .status(PENDING)
            .items(List.of(itemMother.defaultItem()))
            .build();
    }

    static Order completedOrder() {
        return pendingOrder().toBuilder()
            .status(COMPLETED)
            .completedAt(Instant.now())
            .build();
    }
}
```

---

## Test Anti-Patterns to Avoid

### 1. Test Interdependence
```java
// BAD: tests depend on execution order
static User sharedUser;

@Test void test1_createUser() { sharedUser = service.create(...); }
@Test void test2_updateUser() { service.update(sharedUser, ...); }

// GOOD: each test is independent
@Test void shouldCreateUser() { var user = service.create(...); }
@Test void shouldUpdateUser() {
    var user = service.create(...);
    service.update(user, ...);
}
```

### 2. Over-Mocking
```java
// BAD: mocking everything
@Mock Mapper mapper;
@Mock Validator validator;
@Mock Logger logger;

// GOOD: use real implementations where practical
var mapper = new UserMapper();  // stateless, fast
var validator = new UserValidator();
```

### 3. Testing Implementation Details
```java
// BAD: breaks when you refactor
verify(repo, times(1)).findById(any());
verify(cache).get(any());
verify(mapper).toEntity(any());

// GOOD: test observable behavior
assertThat(result.getName()).isEqualTo("expected");
```

### 4. Ignoring Edge Cases
```java
// Always test:
// - null inputs
// - empty collections
// - boundary values
// - error conditions
@ParameterizedTest
@NullAndEmptySource
@ValueSource(strings = {" ", "   "})
void shouldRejectInvalidInput(String input) {
    assertThatThrownBy(() -> service.process(input))
        .isInstanceOf(IllegalArgumentException.class);
}
```

### 5. Slow Tests
```java
// BAD: unnecessary Spring context
@SpringBootTest
class SimpleCalculatorTest { ... }

// GOOD: plain unit test
class SimpleCalculatorTest {
    Calculator calc = new Calculator();
    ...
}
```

---

## Debugging Test Failures

### Common Issues

1. **Flaky tests**: Usually caused by:
   - Time-dependent code (use `Clock`)
   - Shared mutable state
   - Race conditions in async code
   - Random data without seed

2. **Spring context failures**:
   - Check `@ActiveProfiles("test")`
   - Verify `@MockBean` for external dependencies
   - Check for duplicate bean definitions

3. **Database test issues**:
   - Verify `@Transactional` for rollback
   - Check isolation level
   - Use `@DirtiesContext` sparingly (slow)

### Test Isolation Checklist
- [ ] No shared mutable state between tests
- [ ] Database rolled back after each test
- [ ] Mocks reset with `@BeforeEach` or `MockitoExtension`
- [ ] No file system side effects
- [ ] Fixed time/random seeds where needed

---

## Test Coverage Guidelines

### What to Cover
- All public methods of services
- All controller endpoints (happy + error paths)
- Business logic edge cases
- Security boundaries
- Data validation

### What NOT to Obsess Over
- Getters/setters/constructors
- Configuration classes
- Framework code
- Trivial delegation methods

### Coverage Targets
- Line coverage: 70-80% (not a hard rule)
- Branch coverage: Focus on complex conditionals
- Mutation testing: Better metric than line coverage

---

## Test Execution Commands

```bash
# All tests
mvn test

# Single class
mvn test -Dtest=UserServiceTest

# Single method
mvn test -Dtest=UserServiceTest#shouldCreateUser

# By tag
mvn test -Dgroups=integration

# With coverage
mvn test jacoco:report

# Parallel execution
mvn test -DforkCount=2 -DreuseForks=true
```

---

## Checklist for New Tests

- [ ] Test name describes behavior, not method
- [ ] Follows given/when/then structure
- [ ] Uses AssertJ for assertions
- [ ] Independent of other tests
- [ ] Fast (unit < 100ms, integration < 5s)
- [ ] Covers happy path + key error cases
- [ ] No unnecessary mocking
- [ ] Cleans up resources (files, connections)
