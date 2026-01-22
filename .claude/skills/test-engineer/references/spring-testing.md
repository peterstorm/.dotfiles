# Spring Boot Testing Reference

Detailed patterns for Spring Boot integration and controller testing.

## Base Test Configuration

```java
@SpringBootTest
@ActiveProfiles("test")
@Transactional  // rollback after each test
abstract class BaseIntegrationTest {
    @Autowired protected MockMvc mockMvc;
    @MockBean protected ExternalService externalService;
}
```

## Controller Tests with MockMvc

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

## Repository Tests with Testcontainers

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

## Service Integration Tests

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

## Security Testing

### JWT/OAuth2 Patterns

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
