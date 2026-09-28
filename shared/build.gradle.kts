plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.android.library)
}

val sourceRevision = providers.gradleProperty("ftwSourceRevision")
    .orElse(providers.environmentVariable("GITHUB_SHA"))
    .orElse("dev")
val sourceInfoDir = layout.buildDirectory.dir("generated/sourceLicense")
val generateSourceLicense by tasks.registering {
    inputs.property("revision", sourceRevision)
    outputs.dir(sourceInfoDir)
    doLast {
        val revision = sourceRevision.get()
        check(revision == "dev" || revision.matches(Regex("[0-9a-f]{40}")))
        val base = "https://github.com/srcfl/ftw-app"
        val source = if (revision == "dev") base else "$base/archive/$revision.tar.gz"
        val license = "$base/blob/${if (revision == "dev") "main" else revision}/LICENSE"
        val target = sourceInfoDir.get().file("energy/ftw/SourceLicense.kt").asFile
        target.parentFile.mkdirs()
        target.writeText("""
            package energy.ftw
            object SourceLicense {
                val sourceUrl: String = "$source"
                val licenseUrl: String = "$license"
            }
        """.trimIndent())
    }
}

android {
    namespace = "energy.ftw.shared"
    compileSdk = 35
    defaultConfig {
        minSdk = 28
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    androidTarget {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
    jvm()
    // iOS and macOS are pure Swift now: appleApp/ carries its own copy of
    // this logic in FTWKit, checked against the same vectors.

    sourceSets {
        commonMain {
            kotlin.srcDir(sourceInfoDir)
        }
        commonMain.dependencies {
            implementation(libs.kotlinx.coroutines.core)
            implementation("com.ionspin.kotlin:bignum:0.3.10")
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
        }
        androidMain.dependencies {
            implementation(libs.okhttp)
        }
    }
}

tasks.matching { it.name.startsWith("compile") && it.name.contains("Kotlin") }.configureEach {
    dependsOn(generateSourceLicense)
}

tasks.withType<Test>().configureEach {
    environment("FTW_LIVE_BOX", System.getenv("FTW_LIVE_BOX") ?: "")
    environment("FTW_LIVE_RELAY", System.getenv("FTW_LIVE_RELAY") ?: "wss://relay.ftw.energy")
    testLogging {
        events("passed", "skipped", "failed", "standardOut", "standardError")
        showStandardStreams = true
    }
}
