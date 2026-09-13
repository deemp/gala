plugins {
    // Provisions the JDK 21 toolchain the IntelliJ Platform 2025.2 build requires
    // when the JVM running Gradle is older.
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}

rootProject.name = "gala-intellij-plugin"
