package fipsvm;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.security.Security;
import java.sql.DriverManager;
import org.junit.jupiter.api.Test;
import org.testcontainers.postgresql.PostgreSQLContainer;

class PostgresInFipsVmTest {

    @Test
    void testcontainersStartsPostgresAndTheJvmConnects() throws Exception {
        System.out.println("First security provider: " + Security.getProviders()[0].getName());
        // SCRAM authentication runs PBKDF2, which a FIPS-mode JVM only accepts with a password of 14+ characters.
        try (var postgres = new PostgreSQLContainer("postgres:17-alpine").withPassword("fips-vm-selftest-password")) {
            postgres.start();
            try (var connection = DriverManager.getConnection(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword());
                 var result = connection.createStatement().executeQuery("select 1")) {
                result.next();
                assertEquals(1, result.getInt(1));
            }
        }
    }
}
