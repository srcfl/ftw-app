plugins {
    alias(libs.plugins.kotlin.multiplatform)
}

kotlin {
    jvm()

    listOf(
        iosX64(),
        iosArm64(),
        iosSimulatorArm64(),
    ).forEach { target ->
        target.binaries.framework {
            baseName = "Shared"
            isStatic = true
        }
    }

    sourceSets {
        commonMain.dependencies {
            implementation(libs.kotlinx.coroutines.core)
            implementation("com.ionspin.kotlin:bignum:0.3.10")
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
        }
    }
}

tasks.withType<Test>().configureEach {
    environment("FTW_LIVE_BOX", System.getenv("FTW_LIVE_BOX") ?: "")
    environment("FTW_LIVE_RELAY", System.getenv("FTW_LIVE_RELAY") ?: "wss://relay.ftw.energy")
    testLogging {
        events("passed", "skipped", "failed", "standardOut", "standardError")
        showStandardStreams = true
    }
}
