allprojects {
    repositories {
        // 1. 阿里云公共库 (完全替代 mavenCentral，必须放第一位！)
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        // 2. 阿里云 Google 库
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        // 3. 官方源作为最后的兜底备份
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
