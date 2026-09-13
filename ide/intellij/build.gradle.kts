import org.jetbrains.intellij.platform.gradle.TestFrameworkType

plugins {
    id("java")
    id("org.jetbrains.kotlin.jvm") version "2.2.20"
    id("org.jetbrains.intellij.platform") version "2.18.1"
}

val ideaVersion: String by project
val antlr4Version: String by project
val antlr4AdaptorVersion: String by project
val pluginVersion: String by project

group = "org.gala"
version = System.getenv("GALA_VERSION")?.removePrefix("v") ?: pluginVersion

repositories {
    mavenCentral()
    intellijPlatform {
        defaultRepositories()
    }
}

dependencies {
    implementation("org.antlr:antlr4-intellij-adaptor:$antlr4AdaptorVersion")
    implementation("org.antlr:antlr4-runtime:$antlr4Version")

    testImplementation("junit:junit:4.13.2")

    intellijPlatform {
        // GoLand ships the LSP API (com.intellij.modules.lsp) the plugin depends on.
        // The Maven artifact is used rather than the installer; the JetBrains Runtime
        // the tests run on is resolved separately below.
        goland(ideaVersion) { useInstaller = false }
        jetbrainsRuntime()
        bundledPlugin("org.jetbrains.plugins.go")
        testFramework(TestFrameworkType.Platform)
    }
}

intellijPlatform {
    buildSearchableOptions = false

    pluginConfiguration {
        version = project.version.toString()
        ideaVersion {
            sinceBuild = "252"
            untilBuild = "265.*"
        }
    }

    signing {
        certificateChain = providers.environmentVariable("CERTIFICATE_CHAIN")
        privateKey = providers.environmentVariable("PRIVATE_KEY")
        password = providers.environmentVariable("PRIVATE_KEY_PASSWORD")
    }

    publishing {
        token = providers.environmentVariable("PUBLISH_TOKEN")
    }
}

// Include Bazel-generated ANTLR Java sources
sourceSets {
    main {
        java {
            srcDir("src/main/gen")
        }
    }
}

// IntelliJ Platform 2025.2 (build 252) runs on Java 21.
kotlin {
    jvmToolchain(21)
}
