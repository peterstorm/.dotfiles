---
name: security-expert
description: "Expert guidance on API security, web application security, authentication, and authorization. Use this skill when working with JWT tokens, OAuth 2.0/OIDC flows, Keycloak configuration, Spring Security implementation, ABAC/RBAC policies, secure API design, vulnerability assessment, security headers, CORS, CSRF protection, or any authentication/authorization architecture decisions. Triggers on questions about securing APIs, implementing auth flows, configuring identity providers, token validation, access control patterns, security best practices, penetration testing concepts, OWASP guidelines, or debugging security issues in Spring/Keycloak environments."
---

# Security Expert Skill

Expert guidance for API security, authentication, authorization, and identity management.

## Core Competencies

- **Authentication**: JWT, OAuth 2.0, OpenID Connect, SAML, session management
- **Authorization**: RBAC, ABAC, ReBAC, policy engines
- **Identity Providers**: Keycloak, Okta, Auth0, Azure AD
- **Frameworks**: Spring Security, Spring Boot, Jakarta EE Security
- **Web Security**: OWASP Top 10, CSP, CORS, CSRF, XSS prevention

## Quick Reference

### JWT Best Practices
- Always validate: signature, expiration (`exp`), issuer (`iss`), audience (`aud`)
- Use RS256/ES256 for distributed systems (asymmetric), HS256 only for single-service
- Keep tokens short-lived (5-15 min access, hours-days refresh)
- Never store sensitive data in JWT payload (it's base64, not encrypted)
- Implement token revocation via blacklist or short expiry + refresh rotation

### Spring Security + Keycloak Integration Pattern
```java
// Minimal resource server config
@Configuration
@EnableWebSecurity
public class SecurityConfig {
    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http.oauth2ResourceServer(oauth2 -> oauth2.jwt(Customizer.withDefaults()))
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/public/**").permitAll()
                .requestMatchers("/admin/**").hasRole("ADMIN")
                .anyRequest().authenticated());
        return http.build();
    }
}
```

### ABAC vs RBAC Decision Matrix
| Use RBAC when | Use ABAC when |
|---------------|---------------|
| Simple role hierarchy | Context-dependent access (time, location) |
| Static permissions | Resource-level attributes matter |
| Small number of roles | Complex business rules |
| Audit simplicity needed | Fine-grained, dynamic policies |

## Reference Files

For detailed guidance, consult these references:

- **[references/jwt-security.md](references/jwt-security.md)**: Deep dive on JWT vulnerabilities, attack vectors, and secure implementation
- **[references/keycloak.md](references/keycloak.md)**: Keycloak configuration, realm setup, client types, mappers, and flows
- **[references/spring-security.md](references/spring-security.md)**: Spring Security patterns, filter chain, method security, OAuth2 client/resource server
- **[references/authorization-patterns.md](references/authorization-patterns.md)**: RBAC, ABAC, ReBAC implementation patterns and policy engines
- **[references/owasp-api-security.md](references/owasp-api-security.md)**: OWASP API Security Top 10 with mitigations
- **[references/security-headers.md](references/security-headers.md)**: HTTP security headers, CSP, CORS configuration

## Workflow: Security Review

1. **Identify attack surface**: Public endpoints, auth flows, data exposure
2. **Check authentication**: Token validation, session handling, credential storage
3. **Check authorization**: Access control at endpoint and resource level
4. **Review data handling**: Input validation, output encoding, sensitive data exposure
5. **Examine configuration**: Security headers, CORS, error handling, logging
6. **Test edge cases**: Token expiry, concurrent sessions, privilege escalation

## Common Security Pitfalls

```
❌ Trusting JWT without signature validation
❌ Storing tokens in localStorage (XSS vulnerable)
❌ Using symmetric keys across services
❌ Missing audience validation
❌ Exposing stack traces in errors
❌ Permissive CORS (Access-Control-Allow-Origin: *)
❌ Missing rate limiting on auth endpoints
❌ Logging sensitive data (tokens, passwords)
```

## Debugging Security Issues

For auth failures, check in order:
1. Token format and encoding (is it valid JWT structure?)
2. Signature verification (correct algorithm and key?)
3. Claims validation (exp, iss, aud correct?)
4. Role/scope mapping (Keycloak mappers configured?)
5. Spring Security filter chain (debug with `logging.level.org.springframework.security=DEBUG`)
