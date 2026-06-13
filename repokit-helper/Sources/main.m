#import <Foundation/Foundation.h>
#import <roothide.h>
#import <CommonCrypto/CommonDigest.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <pwd.h>
#import <grp.h>
#import <sys/wait.h>
#import <unistd.h>
#import <limits.h>
#import <stdlib.h>
#import <string.h>

extern char **environ;

static NSString *RKLogicalDataRoot(void) {
    return @"/var/mobile/RepoKit";
}

static NSString *RKRealPath(NSString *logicalPath) {
    return jbroot(logicalPath);
}

static NSString *RKRealDataRoot(void) {
    return RKRealPath(RKLogicalDataRoot());
}

static NSString *RKToolSearchPath(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSArray<NSString *> *defaults = @[
        @"/var/jb/usr/bin",
        @"/var/jb/usr/sbin",
        @"/var/jb/bin",
        @"/var/jb/sbin",
        RKRealPath(@"/usr/bin"),
        RKRealPath(@"/usr/sbin"),
        RKRealPath(@"/bin"),
        RKRealPath(@"/sbin"),
        @"/usr/bin",
        @"/usr/sbin",
        @"/bin",
        @"/sbin"
    ];
    for (NSString *item in defaults) {
        if (item.length && ![paths containsObject:item]) [paths addObject:item];
    }
    const char *currentPath = getenv("PATH");
    if (currentPath) {
        for (NSString *item in [@(currentPath) componentsSeparatedByString:@":"]) {
            if (item.length && ![paths containsObject:item]) [paths addObject:item];
        }
    }
    return [paths componentsJoinedByString:@":"];
}

static void RKPrepareCommandEnvironment(void) {
    NSString *toolPath = RKToolSearchPath();
    setenv("PATH", toolPath.UTF8String, 1);
    for (NSString *tarPath in @[@"/var/jb/usr/bin/tar", RKRealPath(@"/usr/bin/tar"), @"/usr/bin/tar"]) {
        if (access(tarPath.fileSystemRepresentation, X_OK) == 0) {
            setenv("TAR", tarPath.UTF8String, 1);
            break;
        }
    }
}

static BOOL RKExecutableExistsAtPath(NSString *path) {
    BOOL isDirectory = NO;
    if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory] || isDirectory) return NO;
    return access(path.fileSystemRepresentation, X_OK) == 0;
}

static void RKAddExecutableCandidate(NSMutableArray<NSString *> *candidates, NSString *path) {
    if (!path.length || [candidates containsObject:path]) return;
    [candidates addObject:path];
}

static NSString *RKResolveExecutablePath(NSString *logicalExecutable) {
    if (!logicalExecutable.length) return logicalExecutable;
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSString *name = logicalExecutable.lastPathComponent.length ? logicalExecutable.lastPathComponent : logicalExecutable;

    if ([logicalExecutable hasPrefix:@"/"]) {
        if (![logicalExecutable hasPrefix:@"/var/jb/"]) {
            RKAddExecutableCandidate(candidates, [@"/var/jb" stringByAppendingString:logicalExecutable]);
        }
        RKAddExecutableCandidate(candidates, logicalExecutable);
        RKAddExecutableCandidate(candidates, RKRealPath(logicalExecutable));
    }

    for (NSString *directory in [RKToolSearchPath() componentsSeparatedByString:@":"]) {
        if (!directory.length) continue;
        RKAddExecutableCandidate(candidates, [directory stringByAppendingPathComponent:name]);
    }

    for (NSString *candidate in candidates) {
        if (RKExecutableExistsAtPath(candidate)) return candidate;
    }
    return candidates.count ? candidates.firstObject : logicalExecutable;
}

static NSFileManager *RKFileManager(void) {
    return [NSFileManager defaultManager];
}

static void RKPrint(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    fprintf(stdout, "%s\n", message.UTF8String ?: "");
}

static void RKPrintErr(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    fprintf(stderr, "%s\n", message.UTF8String ?: "");
}


static NSString *RKStringValue(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    return @"";
}

static uid_t RKMobileUID(void) {
    struct passwd *mobile = getpwnam("mobile");
    return mobile ? mobile->pw_uid : getuid();
}

static gid_t RKMobileGID(void) {
    struct group *mobile = getgrnam("mobile");
    return mobile ? mobile->gr_gid : getgid();
}

static void RKFixOwnershipRecursive(NSString *path) {
    uid_t uid = RKMobileUID();
    gid_t gid = RKMobileGID();
    chown(path.fileSystemRepresentation, uid, gid);
    NSDirectoryEnumerator *enumerator = [RKFileManager() enumeratorAtPath:path];
    for (NSString *item in enumerator) {
        NSString *child = [path stringByAppendingPathComponent:item];
        chown(child.fileSystemRepresentation, uid, gid);
    }
}

static BOOL RKEnsureDirectory(NSString *path, NSError **error) {
    NSDictionary *attributes = @{
        NSFileOwnerAccountID: @(RKMobileUID()),
        NSFileGroupOwnerAccountID: @(RKMobileGID()),
        NSFilePosixPermissions: @0755
    };
    BOOL ok = [RKFileManager() createDirectoryAtPath:path withIntermediateDirectories:YES attributes:attributes error:error];
    if (ok) chown(path.fileSystemRepresentation, RKMobileUID(), RKMobileGID());
    return ok;
}

static NSString *RKNormalizedExistingPath(NSString *path) {
    if (!path.length) return @"";
    NSString *expanded = [path stringByExpandingTildeInPath];
    if ([RKFileManager() fileExistsAtPath:expanded]) return expanded.stringByStandardizingPath;
    NSString *converted = RKRealPath(expanded);
    if ([RKFileManager() fileExistsAtPath:converted]) return converted.stringByStandardizingPath;
    if ([expanded hasPrefix:@"/var/mobile/"]) {
        NSString *jbVarPath = [@"/var/jb" stringByAppendingString:expanded];
        if ([RKFileManager() fileExistsAtPath:jbVarPath]) return jbVarPath.stringByStandardizingPath;
    }
    if ([expanded hasPrefix:@"/private/preboot/"]) {
        NSRange procursusRange = [expanded rangeOfString:@"/procursus" options:NSBackwardsSearch];
        if (procursusRange.location != NSNotFound) {
            NSString *logicalPath = [expanded substringFromIndex:procursusRange.location + @"/procursus".length];
            NSString *convertedLogicalPath = RKRealPath(logicalPath);
            if ([RKFileManager() fileExistsAtPath:convertedLogicalPath]) return convertedLogicalPath.stringByStandardizingPath;
        }
    }
    return expanded.stringByStandardizingPath;
}


static NSString *RKPortablePathForStorage(NSString *inputPath, NSString *realPath) {
    NSString *expanded = [inputPath stringByExpandingTildeInPath];
    if ([expanded hasPrefix:@"/var/mobile/"]) return expanded.stringByStandardizingPath;
    NSRange procursusRange = [realPath rangeOfString:@"/procursus" options:NSBackwardsSearch];
    if (procursusRange.location != NSNotFound) {
        NSString *logicalPath = [realPath substringFromIndex:procursusRange.location + @"/procursus".length];
        if ([logicalPath hasPrefix:@"/var/mobile/"]) return logicalPath.stringByStandardizingPath;
    }
    return realPath.stringByStandardizingPath;
}

static BOOL RKArchitectureMatches(NSString *expectedArchitectures, NSString *architecture) {
    if (!expectedArchitectures.length || !architecture.length) return YES;
    NSCharacterSet *separators = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSArray *parts = [expectedArchitectures componentsSeparatedByCharactersInSet:separators];
    for (NSString *part in parts) {
        if ([part isEqualToString:architecture]) return YES;
    }
    return [expectedArchitectures isEqualToString:architecture];
}

static BOOL RKWriteJSON(id object, NSString *path, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:error];
    if (!data) return NO;
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}

static id RKReadJSON(NSString *path, NSError **error) {
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!data) return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:error];
}

static NSString *RKSlug(NSString *input) {
    NSMutableString *slug = [NSMutableString string];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    for (NSUInteger index = 0; index < input.length; index++) {
        unichar character = [input characterAtIndex:index];
        if ([allowed characterIsMember:character]) {
            [slug appendFormat:@"%C", character];
        } else if ([[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:character]) {
            [slug appendString:@"-"];
        }
    }
    while ([slug containsString:@"--"]) {
        [slug replaceOccurrencesOfString:@"--" withString:@"-" options:0 range:NSMakeRange(0, slug.length)];
    }
    NSString *trimmed = [slug stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"-."]];
    return trimmed.length ? trimmed : @"repo";
}

static NSString *RKIconSlug(NSString *input, NSString *fallback) {
    NSString *source = input.length ? input : fallback;
    NSMutableString *slug = [NSMutableString string];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"];
    for (NSUInteger index = 0; index < source.length; index++) {
        unichar character = [source characterAtIndex:index];
        if ([allowed characterIsMember:character]) {
            [slug appendFormat:@"%C", character];
        } else if ([[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:character] || character == '.') {
            [slug appendString:@"-"];
        }
    }
    while ([slug containsString:@"--"]) {
        [slug replaceOccurrencesOfString:@"--" withString:@"-" options:0 range:NSMakeRange(0, slug.length)];
    }
    NSString *trimmed = [[slug stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"-"]] lowercaseString];
    if (trimmed.length) return trimmed;
    if (fallback.length && ![source isEqualToString:fallback]) return RKIconSlug(fallback, nil);
    return @"icon";
}

static NSString *RKNowString(void) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    return [formatter stringFromDate:[NSDate date]];
}

static NSString *RKReleaseDateString(void) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss 'UTC'";
    return [formatter stringFromDate:[NSDate date]];
}

static NSString *RKRepoPath(NSString *repoID) {
    return [RKRealDataRoot() stringByAppendingPathComponent:[@"repos" stringByAppendingPathComponent:repoID]];
}

static NSString *RKRepoJSONPath(NSString *repoID) {
    return [RKRepoPath(repoID) stringByAppendingPathComponent:@"repo.json"];
}

static NSString *RKPackagesJSONPath(NSString *repoID) {
    return [RKRepoPath(repoID) stringByAppendingPathComponent:@"packages.json"];
}

static NSString *RKDefaultPublicPath(NSString *repoID) {
    return [RKRepoPath(repoID) stringByAppendingPathComponent:@"public"];
}

static NSString *RKPublicPathFromRepo(NSString *repoID, NSDictionary *repo) {
    NSString *publicPath = [repo[@"publicPath"] isKindOfClass:[NSString class]] ? repo[@"publicPath"] : @"";
    if (publicPath.length) return RKNormalizedExistingPath(publicPath).stringByStandardizingPath;
    return RKDefaultPublicPath(repoID);
}

static NSString *RKPublicPath(NSString *repoID) {
    NSDictionary *repo = RKReadJSON(RKRepoJSONPath(repoID), nil);
    return RKPublicPathFromRepo(repoID, [repo isKindOfClass:[NSDictionary class]] ? repo : @{});
}

static NSString *RKRunCommandCapture(NSString *logicalExecutable, NSArray<NSString *> *arguments, NSString *workingDirectory, BOOL mergeStderr, int *exitCode, NSError **error);
static NSString *RKOption(NSArray<NSString *> *args, NSString *name, NSString *fallback);
static BOOL RKBuildRepo(NSString *repoID, NSError **error);

static NSString *RKRunCommand(NSString *logicalExecutable, NSArray<NSString *> *arguments, NSString *workingDirectory, int *exitCode, NSError **error) {
    return RKRunCommandCapture(logicalExecutable, arguments, workingDirectory, YES, exitCode, error);
}

static NSString *RKRunCommandWithEnvironment(NSString *logicalExecutable, NSArray<NSString *> *arguments, NSString *workingDirectory, NSDictionary<NSString *, NSString *> *environment, int *exitCode, NSError **error) {
    NSMutableDictionary<NSString *, NSString *> *previousValues = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *missingKeys = [NSMutableArray array];
    for (NSString *key in environment) {
        if (![key isKindOfClass:[NSString class]] || !key.length) continue;
        const char *oldValue = getenv(key.UTF8String);
        if (oldValue) {
            NSString *previous = [NSString stringWithUTF8String:oldValue];
            if (previous) previousValues[key] = previous;
        } else {
            [missingKeys addObject:key];
        }
        NSString *value = environment[key];
        if ([value isKindOfClass:[NSString class]] && value.length) {
            setenv(key.UTF8String, value.UTF8String, 1);
        } else {
            unsetenv(key.UTF8String);
        }
    }

    NSString *output = RKRunCommand(logicalExecutable, arguments, workingDirectory, exitCode, error);

    for (NSString *key in previousValues) {
        setenv(key.UTF8String, previousValues[key].UTF8String, 1);
    }
    for (NSString *key in missingKeys) {
        unsetenv(key.UTF8String);
    }
    return output;
}

static NSString *RKRunCommandCapture(NSString *logicalExecutable, NSArray<NSString *> *arguments, NSString *workingDirectory, BOOL mergeStderr, int *exitCode, NSError **error) {
    RKPrepareCommandEnvironment();
    NSString *realExecutable = RKResolveExecutablePath(logicalExecutable);
    int stdoutPipe[2];
    if (pipe(stdoutPipe) != 0) {
        if (error) *error = [NSError errorWithDomain:@"RepoKit" code:errno userInfo:@{NSLocalizedDescriptionKey: @"pipe failed"}];
        return nil;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO);
    if (mergeStderr) posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, stdoutPipe[0]);
    posix_spawn_file_actions_addclose(&actions, stdoutPipe[1]);

    char originalDirectory[PATH_MAX];
    BOOL changedDirectory = NO;
    if (workingDirectory.length) {
        if (!getcwd(originalDirectory, sizeof(originalDirectory))) {
            if (error) *error = [NSError errorWithDomain:@"RepoKit" code:errno userInfo:@{NSLocalizedDescriptionKey: @"getcwd failed"}];
            posix_spawn_file_actions_destroy(&actions);
            close(stdoutPipe[0]);
            close(stdoutPipe[1]);
            return nil;
        }
        if (chdir(workingDirectory.fileSystemRepresentation) != 0) {
            if (error) *error = [NSError errorWithDomain:@"RepoKit" code:errno userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"chdir failed: %@", workingDirectory]}];
            posix_spawn_file_actions_destroy(&actions);
            close(stdoutPipe[0]);
            close(stdoutPipe[1]);
            return nil;
        }
        changedDirectory = YES;
    }

    NSUInteger count = arguments.count + 2;
    char **argv = calloc(count, sizeof(char *));
    argv[0] = (char *)logicalExecutable.UTF8String;
    for (NSUInteger index = 0; index < arguments.count; index++) {
        argv[index + 1] = (char *)arguments[index].UTF8String;
    }
    argv[count - 1] = NULL;

    pid_t pid = 0;
    int spawnResult = posix_spawn(&pid, realExecutable.fileSystemRepresentation, &actions, NULL, argv, environ);
    if (changedDirectory) chdir(originalDirectory);
    free(argv);
    posix_spawn_file_actions_destroy(&actions);
    close(stdoutPipe[1]);

    NSMutableData *output = [NSMutableData data];
    if (spawnResult == 0) {
        char buffer[4096];
        ssize_t length = 0;
        while ((length = read(stdoutPipe[0], buffer, sizeof(buffer))) > 0) {
            [output appendBytes:buffer length:(NSUInteger)length];
        }
    }
    close(stdoutPipe[0]);

    if (spawnResult != 0) {
        if (exitCode) *exitCode = spawnResult;
        if (error) {
            *error = [NSError errorWithDomain:@"RepoKit" code:spawnResult userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"spawn failed: %@ (resolved: %@)", logicalExecutable, realExecutable ?: @""]}];
        }
        return nil;
    }

    int status = 0;
    waitpid(pid, &status, 0);
    int code = WIFEXITED(status) ? WEXITSTATUS(status) : status;
    if (exitCode) *exitCode = code;
    NSString *result = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
    return result ?: @"";
}

static void RKSetError(NSError **error, NSInteger code, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"RepoKit" code:code userInfo:@{NSLocalizedDescriptionKey: message ?: @"unknown error"}];
}

static NSString *RKCommandFailureMessage(NSString *command, int exitCode, NSString *output) {
    NSString *trimmed = [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length) return [NSString stringWithFormat:@"%@ failed (%d): %@", command, exitCode, trimmed];
    return [NSString stringWithFormat:@"%@ failed (%d)", command, exitCode];
}

static BOOL RKRunRequiredCommand(NSString *logicalExecutable, NSArray<NSString *> *arguments, NSString *workingDirectory, NSError **error) {
    int exitCode = 0;
    NSString *output = RKRunCommand(logicalExecutable, arguments, workingDirectory, &exitCode, error);
    if (exitCode != 0 || !output) {
        RKSetError(error, exitCode, RKCommandFailureMessage(logicalExecutable.lastPathComponent, exitCode, output));
        return NO;
    }
    return YES;
}

static void RKRunOptionalCommand(NSString *logicalExecutable, NSArray<NSString *> *arguments, NSString *workingDirectory) {
    int exitCode = 0;
    RKRunCommand(logicalExecutable, arguments, workingDirectory, &exitCode, nil);
}

static NSString *RKLogicalSSHKeyPath(void) {
    return @"/var/mobile/.ssh/id_ed25519";
}

static NSString *RKRealSSHKeyPath(void) {
    return RKRealPath(RKLogicalSSHKeyPath());
}

static NSString *RKRealSSHHomePath(void) {
    return RKRealPath(@"/var/mobile");
}

static BOOL RKIsSSHRemote(NSString *remote) {
    NSString *trimmed = [remote stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed hasPrefix:@"ssh://"]) return YES;
    if ([trimmed hasPrefix:@"git@"] && [trimmed rangeOfString:@":"].location != NSNotFound) return YES;
    return NO;
}

static NSString *RKShellSingleQuote(NSString *value) {
    NSString *escaped = [RKStringValue(value) stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    return [NSString stringWithFormat:@"'%@'", escaped];
}

static NSString *RKSSHWrapperPath(NSString *repoID) {
    return [[[RKRepoPath(repoID) stringByAppendingPathComponent:@"logs"] stringByAppendingPathComponent:@"git-ssh-wrapper.sh"] stringByStandardizingPath];
}

static BOOL RKWriteSSHWrapper(NSString *repoID, NSString *sshExecutable, NSString *realSSHKeyPath, NSString **wrapperPath, NSError **error) {
    NSString *logsPath = [[RKRepoPath(repoID) stringByAppendingPathComponent:@"logs"] stringByStandardizingPath];
    if (!RKEnsureDirectory(logsPath, error)) return NO;
    NSString *path = RKSSHWrapperPath(repoID);
    NSString *script = [NSString stringWithFormat:@"#!/bin/sh\nexec %@ -i %@ -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \"$@\"\n", RKShellSingleQuote(sshExecutable), RKShellSingleQuote(realSSHKeyPath)];
    if (![script writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:error]) return NO;
    chmod(path.fileSystemRepresentation, 0700);
    chown(path.fileSystemRepresentation, RKMobileUID(), RKMobileGID());
    if (wrapperPath) *wrapperPath = path;
    return YES;
}

static NSString *RKUniqueTrashPath(NSString *repoID, NSString *fileName) {
    NSString *trashDir = [RKRepoPath(repoID) stringByAppendingPathComponent:@"trash"];
    NSString *safeName = fileName.length ? fileName : @"item";
    NSString *baseName = [NSString stringWithFormat:@"%@-%@", RKNowString(), safeName];
    NSString *destination = [trashDir stringByAppendingPathComponent:baseName];
    NSUInteger suffix = 2;
    while ([RKFileManager() fileExistsAtPath:destination]) {
        NSString *candidate = [NSString stringWithFormat:@"%@-%lu-%@", RKNowString(), (unsigned long)suffix, safeName];
        destination = [trashDir stringByAppendingPathComponent:candidate];
        suffix++;
    }
    return destination;
}

static BOOL RKMoveItemToTrash(NSString *repoID, NSString *path, NSString **trashPath, NSError **error) {
    if (![RKFileManager() fileExistsAtPath:path]) return YES;
    NSString *trashDir = [RKRepoPath(repoID) stringByAppendingPathComponent:@"trash"];
    if (!RKEnsureDirectory(trashDir, error)) return NO;
    NSString *destination = RKUniqueTrashPath(repoID, path.lastPathComponent);
    if (![RKFileManager() moveItemAtPath:path toPath:destination error:error]) return NO;
    if (trashPath) *trashPath = destination;
    return YES;
}

static BOOL RKInstallItemReplacing(NSString *source, NSString *destination, BOOL moveItem, NSString *repoID, NSError **error) {
    NSString *standardSource = source.stringByStandardizingPath;
    NSString *standardDestination = destination.stringByStandardizingPath;
    if ([standardSource isEqualToString:standardDestination]) return YES;
    if ([RKFileManager() fileExistsAtPath:destination]) {
        if (!RKMoveItemToTrash(repoID, destination, nil, error)) return NO;
    }
    NSString *parent = destination.stringByDeletingLastPathComponent;
    if (!RKEnsureDirectory(parent, error)) return NO;
    if (moveItem) return [RKFileManager() moveItemAtPath:source toPath:destination error:error];
    return [RKFileManager() copyItemAtPath:source toPath:destination error:error];
}

static NSString *RKTemporaryDirectory(NSString *prefix, NSError **error) {
    NSString *basePath = [RKRealDataRoot() stringByAppendingPathComponent:@"tmp"];
    if (!RKEnsureDirectory(basePath, error)) return nil;
    NSString *safePrefix = RKSlug(prefix.length ? prefix : @"repokit");
    for (NSUInteger attempt = 0; attempt < 20; attempt++) {
        NSString *name = [NSString stringWithFormat:@"%@-%@-%u-%lu", safePrefix, RKNowString(), arc4random_uniform(UINT32_MAX), (unsigned long)attempt];
        NSString *path = [basePath stringByAppendingPathComponent:name];
        NSDictionary *attributes = @{
            NSFileOwnerAccountID: @(RKMobileUID()),
            NSFileGroupOwnerAccountID: @(RKMobileGID()),
            NSFilePosixPermissions: @0700
        };
        if ([RKFileManager() createDirectoryAtPath:path withIntermediateDirectories:NO attributes:attributes error:nil]) {
            chown(path.fileSystemRepresentation, RKMobileUID(), RKMobileGID());
            return path;
        }
    }
    RKSetError(error, EEXIST, @"create temporary directory failed");
    return nil;
}

static NSString *RKChecksum(NSString *path, BOOL sha256) {
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:path];
    [stream open];
    uint8_t buffer[4096];
    NSInteger readLength = 0;
    if (sha256) {
        CC_SHA256_CTX context;
        CC_SHA256_Init(&context);
        while ((readLength = [stream read:buffer maxLength:sizeof(buffer)]) > 0) {
            CC_SHA256_Update(&context, buffer, (CC_LONG)readLength);
        }
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256_Final(digest, &context);
        [stream close];
        NSMutableString *result = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
        for (int index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) [result appendFormat:@"%02x", digest[index]];
        return result;
    }
    CC_MD5_CTX context;
    CC_MD5_Init(&context);
    while ((readLength = [stream read:buffer maxLength:sizeof(buffer)]) > 0) {
        CC_MD5_Update(&context, buffer, (CC_LONG)readLength);
    }
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5_Final(digest, &context);
    [stream close];
    NSMutableString *result = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int index = 0; index < CC_MD5_DIGEST_LENGTH; index++) [result appendFormat:@"%02x", digest[index]];
    return result;
}

static unsigned long long RKFileSize(NSString *path) {
    NSDictionary *attributes = [RKFileManager() attributesOfItemAtPath:path error:nil];
    return attributes.fileSize;
}

static NSMutableDictionary *RKLoadRepo(NSString *repoID, NSError **error) {
    id object = RKReadJSON(RKRepoJSONPath(repoID), error);
    if ([object isKindOfClass:[NSDictionary class]]) return [object mutableCopy];
    if (error && !*error) *error = [NSError errorWithDomain:@"RepoKit" code:2 userInfo:@{NSLocalizedDescriptionKey: @"repo not found"}];
    return nil;
}

static NSMutableArray<NSMutableDictionary *> *RKLoadPackages(NSString *repoID) {
    id object = RKReadJSON(RKPackagesJSONPath(repoID), nil);
    if ([object isKindOfClass:[NSArray class]]) {
        NSMutableArray *packages = [NSMutableArray array];
        for (id item in (NSArray *)object) {
            if ([item isKindOfClass:[NSDictionary class]]) [packages addObject:[item mutableCopy]];
        }
        return packages;
    }
    return [NSMutableArray array];
}

static BOOL RKSavePackages(NSString *repoID, NSArray *packages, NSError **error) {
    return RKWriteJSON(packages, RKPackagesJSONPath(repoID), error);
}

static NSArray<NSDictionary *> *RKParseControlStanzasWithOrder(NSString *output) {
    NSMutableArray *stanzas = [NSMutableArray array];
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    NSMutableArray *order = [NSMutableArray array];
    NSString *currentKey = nil;
    NSMutableString *currentValue = nil;
    NSArray *lines = [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        if (line.length == 0) {
            if (fields.count) [stanzas addObject:@{@"fields": [fields copy], @"order": [order copy]}];
            fields = [NSMutableDictionary dictionary];
            order = [NSMutableArray array];
            currentKey = nil;
            currentValue = nil;
            continue;
        }
        unichar first = [line characterAtIndex:0];
        if ((first == ' ' || first == '\t') && currentKey && currentValue) {
            [currentValue appendFormat:@"\n%@", [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
            fields[currentKey] = [currentValue copy];
            continue;
        }
        NSRange separator = [line rangeOfString:@":"];
        if (separator.location == NSNotFound) continue;
        currentKey = [[line substringToIndex:separator.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        currentValue = [[line substringFromIndex:separator.location + 1] mutableCopy];
        [currentValue setString:[currentValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
        if (currentKey.length) {
            if (!fields[currentKey]) [order addObject:currentKey];
            fields[currentKey] = [currentValue copy];
        }
    }
    if (fields.count) [stanzas addObject:@{@"fields": [fields copy], @"order": [order copy]}];
    return stanzas;
}

static NSArray<NSDictionary<NSString *, NSString *> *> *RKParseControlStanzas(NSString *output) {
    NSMutableArray *fieldsOnly = [NSMutableArray array];
    for (NSDictionary *stanza in RKParseControlStanzasWithOrder(output)) {
        NSDictionary *fields = stanza[@"fields"];
        if ([fields isKindOfClass:[NSDictionary class]]) [fieldsOnly addObject:fields];
    }
    return fieldsOnly;
}

static NSDictionary *RKDebControlInfoAtPath(NSString *debPath, NSError **error) {
    int exitCode = 0;
    NSString *output = RKRunCommandCapture(@"/usr/bin/dpkg-deb", @[@"-f", debPath], nil, YES, &exitCode, error);
    if (exitCode != 0 || !output.length) {
        RKSetError(error, exitCode ?: 1, [NSString stringWithFormat:@"无法读取 deb control：%@", debPath.lastPathComponent ?: debPath]);
        return nil;
    }
    NSDictionary *stanza = RKParseControlStanzasWithOrder(output).firstObject;
    NSDictionary *fields = [stanza[@"fields"] isKindOfClass:[NSDictionary class]] ? stanza[@"fields"] : nil;
    NSArray *order = [stanza[@"order"] isKindOfClass:[NSArray class]] ? stanza[@"order"] : @[];
    if (!fields.count) {
        RKSetError(error, 12, [NSString stringWithFormat:@"deb control 为空：%@", debPath.lastPathComponent ?: debPath]);
        return nil;
    }
    return @{@"fields": fields, @"order": order};
}

static NSString *RKPackageDisplayName(NSDictionary *control) {
    NSString *name = control[@"Name"];
    if (!name.length) name = control[@"Package"];
    return name ?: @"Unknown";
}

static NSMutableDictionary *RKPackageRecordFromControl(NSDictionary *control, NSArray *scanOrder, NSString *publicPath, NSString *section) {
    NSString *package = control[@"Package"] ?: @"";
    NSString *version = control[@"Version"] ?: @"";
    NSString *architecture = control[@"Architecture"] ?: @"";
    NSString *filename = control[@"Filename"] ?: @"";
    if (!package.length || !version.length || !architecture.length || !filename.length) return nil;

    NSString *debPath = [publicPath stringByAppendingPathComponent:filename];
    NSString *resolvedSection = control[@"Section"] ?: (section ?: @"");

    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"package"] = package;
    record[@"name"] = RKPackageDisplayName(control);
    record[@"version"] = version;
    record[@"architecture"] = architecture;
    record[@"section"] = resolvedSection ?: @"";
    record[@"depends"] = control[@"Depends"] ?: @"";
    record[@"preDepends"] = control[@"Pre-Depends"] ?: @"";
    record[@"maintainer"] = control[@"Maintainer"] ?: @"";
    record[@"author"] = control[@"Author"] ?: @"";
    record[@"description"] = control[@"Description"] ?: @"";
    record[@"depiction"] = control[@"Depiction"] ?: @"";
    record[@"homepage"] = control[@"Homepage"] ?: @"";
    record[@"icon"] = control[@"Icon"] ?: @"";
    record[@"conflicts"] = control[@"Conflicts"] ?: @"";
    record[@"replaces"] = control[@"Replaces"] ?: @"";
    record[@"provides"] = control[@"Provides"] ?: @"";
    record[@"tag"] = control[@"Tag"] ?: @"";
    record[@"filename"] = filename;
    record[@"size"] = @(control[@"Size"] ? strtoull([control[@"Size"] UTF8String], NULL, 10) : RKFileSize(debPath));
    record[@"md5"] = control[@"MD5sum"] ?: @"";
    record[@"sha256"] = control[@"SHA256"] ?: @"";
    record[@"sourcePath"] = debPath;
    record[@"updatedAt"] = RKNowString();
    record[@"control"] = control ?: @{};
    record[@"controlOrder"] = scanOrder ?: @[];
    return record;
}

static NSInteger RKIndexOfPackage(NSArray<NSDictionary *> *packages, NSString *package, NSString *version) {
    for (NSUInteger index = 0; index < packages.count; index++) {
        NSDictionary *record = packages[index];
        if ([record[@"package"] isEqualToString:package] && (!version.length || [record[@"version"] isEqualToString:version])) {
            return (NSInteger)index;
        }
    }
    return NSNotFound;
}

static NSArray<NSString *> *RKDebFilesAtPublicPath(NSString *publicPath, NSError **error) {
    NSString *debsPath = [publicPath stringByAppendingPathComponent:@"debs"];
    NSArray *items = [RKFileManager() contentsOfDirectoryAtPath:debsPath error:error];
    if (!items) return nil;
    NSMutableArray *debs = [NSMutableArray array];
    for (NSString *item in items) {
        if ([item.pathExtension.lowercaseString isEqualToString:@"deb"]) [debs addObject:item];
    }
    return [debs sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

static NSString *RKReleaseHashesForFiles(NSString *publicPath, NSArray<NSString *> *fileNames) {
    NSMutableString *text = [NSMutableString string];
    NSDictionary *sections = @{@"MD5Sum": @NO, @"SHA256": @YES};
    for (NSString *section in @[@"MD5Sum", @"SHA256"]) {
        [text appendFormat:@"%@:\n", section];
        BOOL sha256 = [sections[section] boolValue];
        for (NSString *fileName in fileNames) {
            NSString *path = [publicPath stringByAppendingPathComponent:fileName];
            if (![RKFileManager() fileExistsAtPath:path]) continue;
            NSString *hash = RKChecksum(path, sha256) ?: @"";
            unsigned long long size = RKFileSize(path);
            if (hash.length) [text appendFormat:@" %@ %llu %@\n", hash, size, fileName];
        }
        [text appendString:@"\n"];
    }
    return text;
}

static BOOL RKWriteRelease(NSString *repoID, NSDictionary *repo, NSString *publicPath, NSError **error) {
    NSArray *indexFiles = @[@"Packages", @"Packages.gz", @"Packages.zst", @"Packages.bz2", @"Packages.xz"];
    NSMutableString *release = [NSMutableString stringWithFormat:@"Origin: %@\nLabel: %@\nSuite: stable\nVersion: 1.0\nCodename: ios\nArchitectures: %@\nComponents: main\nDescription: %@\nDate: %@\n\n",
                                repo[@"name"] ?: repoID,
                                repo[@"name"] ?: repoID,
                                repo[@"architecture"] ?: @"iphoneos-arm64",
                                repo[@"description"] ?: @"RepoKit repository",
                                RKReleaseDateString()];
    [release appendString:RKReleaseHashesForFiles(publicPath, indexFiles)];
    return [release writeToFile:[publicPath stringByAppendingPathComponent:@"Release"] atomically:YES encoding:NSUTF8StringEncoding error:error];
}

static NSArray<NSMutableDictionary *> *RKPackageRecordsFromIndexText(NSString *indexText, NSString *publicPath, NSString *section) {
    NSMutableArray *packages = [NSMutableArray array];
    for (NSDictionary *stanza in RKParseControlStanzasWithOrder(indexText)) {
        NSDictionary *control = [stanza[@"fields"] isKindOfClass:[NSDictionary class]] ? stanza[@"fields"] : @{};
        NSArray *order = [stanza[@"order"] isKindOfClass:[NSArray class]] ? stanza[@"order"] : @[];
        NSMutableDictionary *record = RKPackageRecordFromControl(control, order, publicPath, section);
        if (!record) continue;
        NSInteger existing = RKIndexOfPackage(packages, record[@"package"], record[@"version"]);
        if (existing != NSNotFound) [packages removeObjectAtIndex:(NSUInteger)existing];
        [packages addObject:record];
    }
    return packages;
}

static BOOL RKControlRequiredField(NSString *key) {
    return [@[@"Package", @"Version", @"Architecture", @"Maintainer", @"Description"] containsObject:key];
}

static void RKSetControlField(NSMutableDictionary *fields, NSString *key, NSString *value) {
    if (!key.length || !value) return;
    if (!value.length && !RKControlRequiredField(key)) {
        [fields removeObjectForKey:key];
        return;
    }
    fields[key] = value;
}

static void RKAppendControlField(NSMutableString *text, NSString *key, NSString *value) {
    NSString *safeValue = value ?: @"";
    NSArray *lines = [safeValue componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    if (!lines.count) {
        [text appendFormat:@"%@: \n", key];
        return;
    }
    [text appendFormat:@"%@: %@\n", key, lines.firstObject ?: @""];
    for (NSUInteger index = 1; index < lines.count; index++) {
        [text appendFormat:@" %@\n", lines[index]];
    }
}

static NSString *RKControlTextFromFields(NSDictionary *fields) {
    NSArray *preferredKeys = @[
        @"Package", @"Name", @"Version", @"Architecture", @"Section", @"Maintainer", @"Author",
        @"Depends", @"Pre-Depends", @"Conflicts", @"Replaces", @"Provides", @"Tag",
        @"Depiction", @"Homepage", @"Icon", @"Description"
    ];
    NSMutableString *text = [NSMutableString string];
    NSMutableSet *written = [NSMutableSet set];
    for (NSString *key in preferredKeys) {
        NSString *value = fields[key];
        if (![value isKindOfClass:[NSString class]]) continue;
        RKAppendControlField(text, key, value);
        [written addObject:key];
    }
    NSArray *remainingKeys = [[fields allKeys] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    for (NSString *key in remainingKeys) {
        if ([written containsObject:key]) continue;
        NSString *value = fields[key];
        if (![key isKindOfClass:[NSString class]] || ![value isKindOfClass:[NSString class]]) continue;
        RKAppendControlField(text, key, value);
    }
    [text appendString:@"\n"];
    return text;
}

static void RKApplyControlOptions(NSMutableDictionary *fields, NSArray<NSString *> *args) {
    NSDictionary *mapping = @{
        @"--package": @"Package",
        @"--name": @"Name",
        @"--version": @"Version",
        @"--architecture": @"Architecture",
        @"--section": @"Section",
        @"--description": @"Description",
        @"--depends": @"Depends",
        @"--pre-depends": @"Pre-Depends",
        @"--maintainer": @"Maintainer",
        @"--author": @"Author",
        @"--depiction": @"Depiction",
        @"--homepage": @"Homepage",
        @"--conflicts": @"Conflicts",
        @"--replaces": @"Replaces",
        @"--provides": @"Provides",
        @"--tag": @"Tag"
    };
    for (NSString *option in mapping) {
        NSString *value = RKOption(args, option, nil);
        if (value) RKSetControlField(fields, mapping[option], value);
    }
    for (NSUInteger index = 0; index < args.count; index++) {
        if (![args[index] isEqualToString:@"--control-field"] || index + 1 >= args.count) continue;
        NSString *pair = args[index + 1];
        NSRange separator = [pair rangeOfString:@"="];
        if (separator.location == NSNotFound) continue;
        NSString *key = [[pair substringToIndex:separator.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *value = [pair substringFromIndex:separator.location + 1];
        if (key.length) RKSetControlField(fields, key, value ?: @"");
    }
}

static BOOL RKApplyRepoIconOption(NSString *repoID, NSString *publicPath, NSMutableDictionary *repo, NSArray<NSString *> *args, NSError **error) {
    NSString *iconInput = RKOption(args, @"--icon", nil);
    if (!iconInput || !iconInput.length) return YES;

    NSString *realIconPath = RKNormalizedExistingPath(iconInput);
    if (![RKFileManager() fileExistsAtPath:realIconPath]) {
        RKSetError(error, 6, [NSString stringWithFormat:@"源图标文件不存在：%@", iconInput]);
        return NO;
    }
    if (![realIconPath.pathExtension.lowercaseString isEqualToString:@"png"]) {
        RKSetError(error, 7, @"源图标仅支持 png，并会复制为 CydiaIcon.png");
        return NO;
    }

    NSString *destination = [publicPath stringByAppendingPathComponent:@"CydiaIcon.png"];
    if (!RKInstallItemReplacing(realIconPath, destination, NO, repoID, error)) return NO;
    chown(destination.fileSystemRepresentation, RKMobileUID(), RKMobileGID());
    repo[@"icon"] = @"CydiaIcon.png";
    return YES;
}

static BOOL RKApplyIconOption(NSString *repoID, NSDictionary *repo, NSString *publicPath, NSString *iconBaseName, NSMutableDictionary *fields, NSArray<NSString *> *args, NSError **error) {
    NSString *iconInput = RKOption(args, @"--icon", nil);
    if (!iconInput) return YES;
    if (!iconInput.length) {
        [fields removeObjectForKey:@"Icon"];
        return YES;
    }

    NSString *realIconPath = RKNormalizedExistingPath(iconInput);
    if (![RKFileManager() fileExistsAtPath:realIconPath]) {
        RKSetError(error, 6, [NSString stringWithFormat:@"图标文件不存在：%@", iconInput]);
        return NO;
    }
    NSString *extension = realIconPath.pathExtension.lowercaseString;
    if (![@[@"png", @"jpg", @"jpeg"] containsObject:extension]) {
        RKSetError(error, 7, @"图标仅支持 png、jpg 或 jpeg");
        return NO;
    }

    NSString *iconsPath = [publicPath stringByAppendingPathComponent:@"icons"];
    if (!RKEnsureDirectory(iconsPath, error)) return NO;
    NSString *iconName = [NSString stringWithFormat:@"%@.%@", RKIconSlug(iconBaseName, fields[@"Package"]), extension];
    NSString *iconDestination = [iconsPath stringByAppendingPathComponent:iconName];
    if (!RKInstallItemReplacing(realIconPath, iconDestination, NO, repoID, error)) return NO;

    NSString *baseURL = [repo[@"baseURL"] isKindOfClass:[NSString class]] ? repo[@"baseURL"] : @"";
    while ([baseURL hasSuffix:@"/"]) baseURL = [baseURL substringToIndex:baseURL.length - 1];
    NSString *iconValue = baseURL.length ? [NSString stringWithFormat:@"%@/icons/%@", baseURL, iconName] : [NSString stringWithFormat:@"icons/%@", iconName];
    fields[@"Icon"] = iconValue;
    chown(iconDestination.fileSystemRepresentation, RKMobileUID(), RKMobileGID());
    return YES;
}

static BOOL RKEditDebPackage(NSString *repoID, NSString *package, NSString *version, NSArray<NSString *> *args, NSError **error) {
    NSMutableDictionary *repo = RKLoadRepo(repoID, error);
    if (!repo) return NO;
    NSString *publicPath = RKPublicPathFromRepo(repoID, repo);
    NSMutableArray *packages = RKLoadPackages(repoID);
    NSInteger index = RKIndexOfPackage(packages, package, version);
    if (index == NSNotFound) {
        RKSetError(error, 8, @"包不存在");
        return NO;
    }

    NSDictionary *record = packages[(NSUInteger)index];
    NSString *filename = record[@"filename"];
    if (!filename.length) {
        RKSetError(error, 9, @"包记录缺少 filename 字段");
        return NO;
    }
    NSString *debPath = [filename hasPrefix:@"/"] ? RKNormalizedExistingPath(filename) : [publicPath stringByAppendingPathComponent:filename];
    if (![RKFileManager() fileExistsAtPath:debPath]) {
        RKSetError(error, 10, [NSString stringWithFormat:@"deb 文件不存在：%@", debPath]);
        return NO;
    }

    NSString *workDir = RKTemporaryDirectory(@"repokit-edit", error);
    if (!workDir) return NO;
    BOOL ok = NO;
    do {
        NSString *unpackDir = [workDir stringByAppendingPathComponent:@"payload"];
        if (!RKEnsureDirectory(unpackDir, error)) break;
        if (!RKRunRequiredCommand(@"/usr/bin/dpkg-deb", @[@"-R", debPath, unpackDir], nil, error)) break;

        NSString *controlPath = [unpackDir stringByAppendingPathComponent:@"DEBIAN/control"];
        NSString *controlText = [NSString stringWithContentsOfFile:controlPath encoding:NSUTF8StringEncoding error:error];
        if (!controlText.length) {
            RKSetError(error, 11, @"DEBIAN/control 为空或无法读取");
            break;
        }
        NSArray *stanzas = RKParseControlStanzas(controlText);
        NSMutableDictionary *fields = [stanzas.firstObject isKindOfClass:[NSDictionary class]] ? [stanzas.firstObject mutableCopy] : [NSMutableDictionary dictionary];
        if (!fields[@"Package"]) fields[@"Package"] = package;
        RKApplyControlOptions(fields, args);
        NSString *iconBaseName = fields[@"Name"] ?: fields[@"Package"] ?: package;
        if (!RKApplyIconOption(repoID, repo, publicPath, iconBaseName, fields, args, error)) break;

        NSString *updatedControl = RKControlTextFromFields(fields);
        if (![updatedControl writeToFile:controlPath atomically:YES encoding:NSUTF8StringEncoding error:error]) break;

        NSString *newDebPath = [workDir stringByAppendingPathComponent:debPath.lastPathComponent];
        if (!RKRunRequiredCommand(@"/usr/bin/dpkg-deb", @[@"-b", unpackDir, newDebPath], nil, error)) break;

        NSString *originalTrashPath = nil;
        if (!RKMoveItemToTrash(repoID, debPath, &originalTrashPath, error)) break;
        if (![RKFileManager() moveItemAtPath:newDebPath toPath:debPath error:error]) {
            if (originalTrashPath.length && [RKFileManager() fileExistsAtPath:originalTrashPath] && ![RKFileManager() fileExistsAtPath:debPath]) {
                [RKFileManager() moveItemAtPath:originalTrashPath toPath:debPath error:nil];
            }
            break;
        }
        chown(debPath.fileSystemRepresentation, RKMobileUID(), RKMobileGID());
        if (!RKBuildRepo(repoID, error)) break;
        ok = YES;
    } while (NO);

    [RKFileManager() removeItemAtPath:workDir error:nil];
    return ok;
}

static NSString *RKScanPackagesOutput(NSString *publicPath, int *exitCode, NSError **error) {
    NSString *toolPath = RKToolSearchPath();
    NSString *command = [NSString stringWithFormat:@"PATH=%@; export PATH; exec dpkg-scanpackages debs/ /dev/null 2>/dev/null", toolPath];
    return RKRunCommandCapture(@"/usr/bin/sh", @[@"-c", command], publicPath, NO, exitCode, error);
}

static NSString *RKScanPackagesDiagnostic(NSString *publicPath) {
    NSString *toolPath = RKToolSearchPath();
    NSString *command = [NSString stringWithFormat:@"PATH=%@; export PATH; dpkg-scanpackages debs/ /dev/null >/dev/null", toolPath];
    int exitCode = 0;
    NSString *diagnostic = RKRunCommandCapture(@"/usr/bin/sh", @[@"-c", command], publicPath, YES, &exitCode, nil);
    NSString *trimmed = [diagnostic stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length ? trimmed : [NSString stringWithFormat:@"dpkg-scanpackages failed (%d)", exitCode];
}

static NSString *RKPackagesIndexSignature(NSString *publicPath) {
    NSArray<NSString *> *indexNames = @[@"Packages", @"Packages.gz", @"Packages.zst", @"Packages.bz2", @"Packages.xz"];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *name in indexNames) {
        NSString *path = [publicPath stringByAppendingPathComponent:name];
        NSDictionary *attributes = [RKFileManager() attributesOfItemAtPath:path error:nil];
        if (!attributes) continue;
        NSDate *modified = attributes[NSFileModificationDate];
        unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
        NSTimeInterval timestamp = [modified isKindOfClass:[NSDate class]] ? modified.timeIntervalSince1970 : 0;
        [parts addObject:[NSString stringWithFormat:@"%@:%llu:%.0f", name, size, timestamp]];
    }
    return [parts componentsJoinedByString:@"|"];
}

static BOOL RKBuildRepo(NSString *repoID, NSError **error) {
    NSMutableDictionary *repo = RKLoadRepo(repoID, error);
    if (!repo) return NO;
    NSString *publicPath = RKPublicPath(repoID);
    NSString *debsPath = [publicPath stringByAppendingPathComponent:@"debs"];
    if (!RKEnsureDirectory(debsPath, error)) return NO;

    NSArray *debs = RKDebFilesAtPublicPath(publicPath, error);
    if (!debs) return NO;

    NSString *scanOutput = @"";
    if (debs.count) {
        int exitCode = 0;
        scanOutput = RKScanPackagesOutput(publicPath, &exitCode, error);
        if (exitCode != 0 || !scanOutput.length) {
            NSString *diagnostic = RKScanPackagesDiagnostic(publicPath);
            RKSetError(error, exitCode, RKCommandFailureMessage(@"dpkg-scanpackages", exitCode, diagnostic));
            return NO;
        }
    }

    NSString *packagesPath = [publicPath stringByAppendingPathComponent:@"Packages"];
    if (![scanOutput writeToFile:packagesPath atomically:YES encoding:NSUTF8StringEncoding error:error]) return NO;

    for (NSString *indexName in @[@"Packages.gz", @"Packages.zst", @"Packages.bz2", @"Packages.xz"]) {
        [RKFileManager() removeItemAtPath:[publicPath stringByAppendingPathComponent:indexName] error:nil];
    }
    if (!RKRunRequiredCommand(@"/usr/bin/gzip", @[@"-9", @"-f", @"-k", @"Packages"], publicPath, error)) return NO;
    RKRunOptionalCommand(@"/usr/bin/zstd", @[@"-f", @"Packages", @"-o", @"Packages.zst"], publicPath);
    RKRunOptionalCommand(@"/usr/bin/bzip2", @[@"-k", @"-f", @"Packages"], publicPath);
    RKRunOptionalCommand(@"/usr/bin/xz", @[@"-k", @"-f", @"Packages"], publicPath);

    if (!RKWriteRelease(repoID, repo, publicPath, error)) return NO;

    NSArray *packages = RKPackageRecordsFromIndexText(scanOutput, publicPath, nil);
    repo[@"updatedAt"] = RKNowString();
    repo[@"lastBuildAt"] = RKNowString();
    repo[@"packageCount"] = @(packages.count);
    repo[@"packagesIndexSignature"] = RKPackagesIndexSignature(publicPath) ?: @"";
    if (!RKWriteJSON(repo, RKRepoJSONPath(repoID), error)) return NO;
    return RKSavePackages(repoID, packages, error);
}

static NSDictionary *RKReleaseFieldsAtPath(NSString *releasePath) {
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    NSString *text = [NSString stringWithContentsOfFile:releasePath encoding:NSUTF8StringEncoding error:nil];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSRange separator = [line rangeOfString:@":"];
        if (separator.location == NSNotFound) continue;
        NSString *key = [[line substringToIndex:separator.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *value = [[line substringFromIndex:separator.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (key.length && value.length) fields[key] = value;
    }
    return fields;
}

static NSString *RKReadPackagesIndexText(NSString *publicPath) {
    NSString *packagesPath = [publicPath stringByAppendingPathComponent:@"Packages"];
    NSString *text = [NSString stringWithContentsOfFile:packagesPath encoding:NSUTF8StringEncoding error:nil];
    if (text.length) return text;

    NSArray *compressedIndexes = @[
        @{@"path": [publicPath stringByAppendingPathComponent:@"Packages.gz"], @"tool": @"/usr/bin/gzip", @"args": @[@"-dc"]},
        @{@"path": [publicPath stringByAppendingPathComponent:@"Packages.zst"], @"tool": @"/usr/bin/zstd", @"args": @[@"-dc"]}
    ];
    for (NSDictionary *item in compressedIndexes) {
        NSString *path = item[@"path"];
        if (![RKFileManager() fileExistsAtPath:path]) continue;
        NSMutableArray *arguments = [item[@"args"] mutableCopy];
        [arguments addObject:path];
        int exitCode = 0;
        NSString *output = RKRunCommand(item[@"tool"], arguments, nil, &exitCode, nil);
        if (exitCode == 0 && output.length) return output;
    }
    return nil;
}

static BOOL RKImportPackagesIndexFromPublicPath(NSString *repoID, NSString *publicPath, NSString *section, NSError **error) {
    NSString *indexText = RKReadPackagesIndexText(publicPath);
    if (!indexText.length) return NO;
    NSArray *packages = RKPackageRecordsFromIndexText(indexText, publicPath, section);
    if (!packages.count) return NO;
    if (!RKSavePackages(repoID, packages, error)) return NO;
    NSMutableDictionary *repo = RKLoadRepo(repoID, nil);
    if (repo) {
        repo[@"packageCount"] = @(packages.count);
        repo[@"packagesIndexSignature"] = RKPackagesIndexSignature(publicPath) ?: @"";
        repo[@"updatedAt"] = RKNowString();
        RKWriteJSON(repo, RKRepoJSONPath(repoID), nil);
    }
    return YES;
}

static BOOL RKRefreshPackagesCacheIfNeeded(NSString *repoID, NSString *publicPath, NSError **error) {
    NSString *signature = RKPackagesIndexSignature(publicPath);
    if (!signature.length) return NO;
    NSDictionary *repo = RKLoadRepo(repoID, nil);
    NSString *cachedSignature = RKStringValue(repo[@"packagesIndexSignature"]);
    BOOL hasCacheFile = [RKFileManager() fileExistsAtPath:RKPackagesJSONPath(repoID)];
    if (hasCacheFile && cachedSignature.length && [cachedSignature isEqualToString:signature]) return YES;
    return RKImportPackagesIndexFromPublicPath(repoID, publicPath, nil, error);
}

static BOOL RKImportExistingSource(NSString *sourcePath, NSString *repoID, NSString *name, NSString *baseURL, NSError **error) {
    NSString *realSourcePath = RKNormalizedExistingPath(sourcePath);
    BOOL isDirectory = NO;
    if (![RKFileManager() fileExistsAtPath:realSourcePath isDirectory:&isDirectory] || !isDirectory) {
        if (error) *error = [NSError errorWithDomain:@"RepoKit" code:4 userInfo:@{NSLocalizedDescriptionKey: @"source path is not a directory"}];
        return NO;
    }
    NSString *realRepoID = RKSlug(repoID.length ? repoID : realSourcePath.lastPathComponent);
    NSString *repoPath = RKRepoPath(realRepoID);
    NSDictionary *existingRepo = RKReadJSON(RKRepoJSONPath(realRepoID), nil);

    NSDictionary *release = RKReleaseFieldsAtPath([realSourcePath stringByAppendingPathComponent:@"Release"]);
    NSString *repoName = name.length ? name : (release[@"Label"] ?: release[@"Origin"] ?: realRepoID);
    NSString *architecture = release[@"Architectures"] ?: (existingRepo[@"architecture"] ?: @"iphoneos-arm64");

    if (!RKEnsureDirectory(repoPath, error)) return NO;
    NSString *publicPath = realSourcePath.stringByStandardizingPath;
    NSString *storedPublicPath = RKPortablePathForStorage(sourcePath, publicPath);
    BOOL hasExistingIndex = RKReadPackagesIndexText(publicPath).length > 0;
    RKEnsureDirectory([repoPath stringByAppendingPathComponent:@"trash"], nil);
    RKEnsureDirectory([repoPath stringByAppendingPathComponent:@"logs"], nil);
    RKEnsureDirectory([publicPath stringByAppendingPathComponent:@"debs"], nil);
    RKEnsureDirectory([publicPath stringByAppendingPathComponent:@"icons"], nil);
    NSArray *sourceDebs = RKDebFilesAtPublicPath(publicPath, nil) ?: @[];
    if (!hasExistingIndex && !sourceDebs.count) {
        RKSetError(error, 13, @"未找到 Packages/Packages.gz，也未找到 debs/*.deb");
        return NO;
    }

    NSMutableDictionary *repo = [([existingRepo isKindOfClass:[NSDictionary class]] ? existingRepo : @{}) mutableCopy];
    repo[@"id"] = realRepoID;
    repo[@"name"] = repoName;
    repo[@"description"] = release[@"Description"] ?: repo[@"description"] ?: @"Imported jailbreak repository";
    repo[@"author"] = repo[@"author"] ?: @"DaFei";
    repo[@"baseURL"] = baseURL ?: repo[@"baseURL"] ?: @"";
    repo[@"scheme"] = repo[@"scheme"] ?: @"rootless";
    repo[@"architecture"] = architecture;
    repo[@"sourcePath"] = storedPublicPath;
    repo[@"publicPath"] = storedPublicPath;
    repo[@"createdAt"] = repo[@"createdAt"] ?: RKNowString();
    repo[@"updatedAt"] = RKNowString();
    repo[@"packageCount"] = @0;
    if (!RKWriteJSON(repo, RKRepoJSONPath(realRepoID), error)) return NO;
    if (hasExistingIndex) RKImportPackagesIndexFromPublicPath(realRepoID, publicPath, nil, nil);
    if (!hasExistingIndex && !RKBuildRepo(realRepoID, error)) return NO;
    NSMutableArray *packages = RKLoadPackages(realRepoID);
    repo[@"packageCount"] = @(packages.count);
    repo[@"updatedAt"] = RKNowString();
    if (!RKWriteJSON(repo, RKRepoJSONPath(realRepoID), error)) return NO;
    RKFixOwnershipRecursive(repoPath);
    return YES;
}

static BOOL RKRescanRepo(NSString *repoID, BOOL deepScan, NSError **error) {
    if (!RKLoadRepo(repoID, error)) return NO;
    (void)deepScan;
    return RKBuildRepo(repoID, error);
}

static void RKAutoRescanIfNeeded(NSString *repoID) {
    (void)repoID;
}

static NSArray<NSString *> *RKCheckRepo(NSString *repoID) {
    NSMutableArray *issues = [NSMutableArray array];
    NSDictionary *repo = RKLoadRepo(repoID, nil);
    if (!repo) return @[@"源不存在"];
    NSArray *packages = RKLoadPackages(repoID);
    NSMutableSet *seen = [NSMutableSet set];
    NSString *expectedArch = repo[@"architecture"];
    for (NSDictionary *record in packages) {
        NSString *package = record[@"package"] ?: @"";
        NSString *version = record[@"version"] ?: @"";
        NSString *architecture = record[@"architecture"] ?: @"";
        NSString *key = [NSString stringWithFormat:@"%@|%@", package, version];
        if (!package.length) [issues addObject:@"存在缺少 package 字段的记录"];
        if (!version.length) [issues addObject:[NSString stringWithFormat:@"%@ 缺少 version 字段", package]];
        if ([seen containsObject:key]) [issues addObject:[NSString stringWithFormat:@"重复包版本：%@ %@", package, version]];
        [seen addObject:key];
        if (!RKArchitectureMatches(expectedArch, architecture)) {
            [issues addObject:[NSString stringWithFormat:@"架构不匹配：%@ %@，期望 %@", package, architecture, expectedArch]];
        }
        NSString *filename = record[@"filename"];
        if (!filename.length || ![RKFileManager() fileExistsAtPath:[RKPublicPath(repoID) stringByAppendingPathComponent:filename]]) {
            [issues addObject:[NSString stringWithFormat:@"deb 文件丢失：%@ %@", package, version]];
        }
    }
    return issues.count ? issues : @[@"OK"];
}

static void RKPrintUsage(void) {
    RKPrint(@"RepoKit helper 0.1.0");
    RKPrint(@"用法:");
    RKPrint(@"  repokit-helper repos");
    RKPrint(@"  repokit-helper init <repo-id> [--name 名称] [--description 描述] [--author 作者] [--base-url URL] [--scheme rootless|roothide] [--architecture iphoneos-arm64|iphoneos-arm64e]");
    RKPrint(@"  repokit-helper import-source <path> [--repo-id ID] [--name 名称] [--base-url URL]");
    RKPrint(@"  repokit-helper repo <repo-id>");
    RKPrint(@"  repokit-helper repo-edit <repo-id> [--name 名称] [--description 描述] [--base-url URL] [--scheme 模式] [--architecture 架构] [--icon PNG路径]");
    RKPrint(@"  repokit-helper delete-repo <repo-id>");
    RKPrint(@"  repokit-helper add <repo-id> <deb-path> [--move]");
    RKPrint(@"  repokit-helper add-many <repo-id> <deb-path> [deb-path...]");
    RKPrint(@"  repokit-helper inspect-deb <deb-path>");
    RKPrint(@"  repokit-helper installed");
    RKPrint(@"  repokit-helper repack-installed <repo-id> <package-id> [package-id...]");
    RKPrint(@"  repokit-helper rescan <repo-id> [--deep]");
    RKPrint(@"  repokit-helper list <repo-id>");
    RKPrint(@"  repokit-helper show <repo-id> <package> [version]");
    RKPrint(@"  repokit-helper edit <repo-id> <package> <version> [--name 名称] [--section 分类] [--description 描述] [--depiction URL]");
    RKPrint(@"  repokit-helper edit-deb <repo-id> <package> <version> [--package 包ID] [--name 名称] [--version 版本] [--architecture 架构] [--section 分类] [--description 描述] [--depends 依赖] [--maintainer 维护者] [--author 作者] [--depiction URL] [--homepage URL] [--icon 本地图标] [--control-field Key=Value]");
    RKPrint(@"  repokit-helper remove <repo-id> <package> [version] [--delete-file]");
    RKPrint(@"  repokit-helper build <repo-id>");
    RKPrint(@"  repokit-helper check <repo-id>");
    RKPrint(@"  repokit-helper github <repo-id> [--remote SSH_URL] [--branch main] [--user 用户] [--email 邮箱]");
    RKPrint(@"  repokit-helper push <repo-id> [--message 文本]");
}

static NSString *RKOption(NSArray<NSString *> *args, NSString *name, NSString *fallback) {
    NSUInteger index = [args indexOfObject:name];
    if (index != NSNotFound && index + 1 < args.count) return args[index + 1];
    return fallback;
}

static BOOL RKHasFlag(NSArray<NSString *> *args, NSString *name) {
    return [args containsObject:name];
}

static int RKCommandRepos(void) {
    NSError *error = nil;
    NSString *reposPath = [RKRealDataRoot() stringByAppendingPathComponent:@"repos"];
    RKEnsureDirectory(reposPath, nil);
    NSArray *items = [RKFileManager() contentsOfDirectoryAtPath:reposPath error:&error];
    if (!items) {
        RKPrintErr(@"读取源列表失败：%@", error.localizedDescription);
        return 1;
    }
    NSMutableArray *repos = [NSMutableArray array];
    for (NSString *item in items) {
        RKAutoRescanIfNeeded(item);
        NSDictionary *repo = RKReadJSON([reposPath stringByAppendingPathComponent:[item stringByAppendingPathComponent:@"repo.json"]], nil);
        if ([repo isKindOfClass:[NSDictionary class]]) [repos addObject:repo];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:repos options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    RKPrint(@"%@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    return 0;
}

static int RKCommandInit(NSArray<NSString *> *args) {
    if (args.count < 3) { RKPrintUsage(); return 2; }
    NSString *repoID = RKSlug(args[2]);
    NSString *name = RKOption(args, @"--name", repoID);
    NSString *description = RKOption(args, @"--description", @"Personal jailbreak repository");
    NSString *author = RKOption(args, @"--author", @"DaFei");
    NSString *baseURL = RKOption(args, @"--base-url", @"");
    NSString *scheme = RKOption(args, @"--scheme", @"rootless");
    NSString *architecture = RKOption(args, @"--architecture", [scheme isEqualToString:@"roothide"] ? @"iphoneos-arm64e" : @"iphoneos-arm64");
    NSString *repoPath = RKRepoPath(repoID);
    if ([RKFileManager() fileExistsAtPath:RKRepoJSONPath(repoID)]) {
        RKPrintErr(@"源已存在：%@", repoID);
        return 1;
    }
    NSError *error = nil;
    NSArray *dirs = @[@"debs", @"public", @"public/debs", @"public/icons", @"depictions", @"trash", @"logs"];
    for (NSString *dir in dirs) {
        if (!RKEnsureDirectory([repoPath stringByAppendingPathComponent:dir], &error)) {
            RKPrintErr(@"创建目录失败：%@", error.localizedDescription);
            return 1;
        }
    }
    NSMutableDictionary *repo = [@{
        @"id": repoID,
        @"name": name,
        @"description": description,
        @"author": author,
        @"baseURL": baseURL,
        @"scheme": scheme,
        @"architecture": architecture,
        @"publicPath": RKDefaultPublicPath(repoID),
        @"createdAt": RKNowString(),
        @"updatedAt": RKNowString(),
        @"packageCount": @0
    } mutableCopy];
    if (!RKWriteJSON(repo, RKRepoJSONPath(repoID), &error) || !RKSavePackages(repoID, @[], &error)) {
        RKPrintErr(@"写入源失败：%@", error.localizedDescription);
        return 1;
    }
    RKFixOwnershipRecursive(repoPath);
    RKPrint(@"已创建源：%@", repoID);
    return 0;
}

static int RKCommandImportSource(NSArray<NSString *> *args) {
    if (args.count < 3) { RKPrintUsage(); return 2; }
    NSString *sourcePath = args[2];
    NSString *repoID = RKOption(args, @"--repo-id", sourcePath.lastPathComponent);
    NSString *name = RKOption(args, @"--name", repoID);
    NSString *baseURL = RKOption(args, @"--base-url", @"");
    NSError *error = nil;
    if (!RKImportExistingSource(sourcePath, repoID, name, baseURL, &error)) {
        RKPrintErr(@"导入源失败：%@", error.localizedDescription);
        return 1;
    }
    RKPrint(@"已导入已有源：%@", RKSlug(repoID));
    return 0;
}

static int RKCommandRepo(NSArray<NSString *> *args) {
    if (args.count < 3) { RKPrintUsage(); return 2; }
    RKAutoRescanIfNeeded(args[2]);
    NSError *error = nil;
    NSDictionary *repo = RKLoadRepo(args[2], &error);
    if (!repo) { RKPrintErr(@"读取源失败：%@", error.localizedDescription); return 1; }
    NSData *data = [NSJSONSerialization dataWithJSONObject:repo options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    RKPrint(@"%@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    return 0;
}

static int RKCommandRepoEdit(NSArray<NSString *> *args) {
    if (args.count < 3) { RKPrintUsage(); return 2; }
    NSError *error = nil;
    NSMutableDictionary *repo = RKLoadRepo(args[2], &error);
    if (!repo) { RKPrintErr(@"读取源失败：%@", error.localizedDescription); return 1; }
    NSDictionary *mapping = @{@"--name": @"name", @"--description": @"description", @"--base-url": @"baseURL", @"--scheme": @"scheme", @"--architecture": @"architecture", @"--author": @"author"};
    for (NSString *option in mapping) {
        NSString *value = RKOption(args, option, nil);
        if (value) repo[mapping[option]] = value;
    }
    NSString *publicPath = RKPublicPathFromRepo(args[2], repo);
    if (!RKEnsureDirectory(publicPath, &error) || !RKApplyRepoIconOption(args[2], publicPath, repo, args, &error)) {
        RKPrintErr(@"保存源图标失败：%@", error.localizedDescription);
        return 1;
    }
    repo[@"updatedAt"] = RKNowString();
    if (!RKWriteJSON(repo, RKRepoJSONPath(args[2]), &error)) {
        RKPrintErr(@"保存源失败：%@", error.localizedDescription);
        return 1;
    }
    RKPrint(@"已更新源：%@", args[2]);
    return 0;
}

static int RKCommandDeleteRepo(NSArray<NSString *> *args) {
    if (args.count < 3) { RKPrintUsage(); return 2; }
    NSString *repoID = args[2];
    NSString *repoPath = RKRepoPath(repoID);
    if (![RKFileManager() fileExistsAtPath:repoPath]) {
        RKPrintErr(@"源不存在：%@", repoID);
        return 1;
    }
    NSString *trashRoot = [RKRealDataRoot() stringByAppendingPathComponent:@"repo-trash"];
    NSError *error = nil;
    RKEnsureDirectory(trashRoot, nil);
    NSString *destination = [trashRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@", repoID, RKNowString()]];
    if (![RKFileManager() moveItemAtPath:repoPath toPath:destination error:&error]) {
        RKPrintErr(@"删除源失败：%@", error.localizedDescription);
        return 1;
    }
    RKPrint(@"已移动到回收目录：%@", destination);
    return 0;
}

static BOOL RKCopyDebIntoRepo(NSString *repoID, NSString *inputPath, BOOL moveDeb, NSString **destinationName, NSError **error) {
    NSString *realDebPath = [inputPath hasPrefix:@"/"] ? RKNormalizedExistingPath(inputPath) : [[RKFileManager() currentDirectoryPath] stringByAppendingPathComponent:inputPath];
    if (![RKFileManager() fileExistsAtPath:realDebPath]) {
        NSString *converted = RKRealPath(inputPath);
        if ([RKFileManager() fileExistsAtPath:converted]) realDebPath = converted;
    }
    if (![RKFileManager() fileExistsAtPath:realDebPath]) {
        RKSetError(error, 20, [NSString stringWithFormat:@"deb 文件不存在：%@", inputPath]);
        return NO;
    }
    if (![realDebPath.pathExtension.lowercaseString isEqualToString:@"deb"]) {
        RKSetError(error, 21, [NSString stringWithFormat:@"不是 deb 文件：%@", inputPath]);
        return NO;
    }
    NSString *debsPath = [RKPublicPath(repoID) stringByAppendingPathComponent:@"debs"];
    if (!RKEnsureDirectory(debsPath, error)) return NO;
    NSString *destination = [debsPath stringByAppendingPathComponent:realDebPath.lastPathComponent];
    if (!RKInstallItemReplacing(realDebPath, destination, moveDeb, repoID, error)) return NO;
    chown(destination.fileSystemRepresentation, RKMobileUID(), RKMobileGID());
    if (destinationName) *destinationName = destination.lastPathComponent;
    return YES;
}

static int RKCommandAdd(NSArray<NSString *> *args) {
    if (args.count < 4) { RKPrintUsage(); return 2; }
    NSString *repoID = args[2];
    BOOL moveDeb = RKHasFlag(args, @"--move");
    NSError *error = nil;
    if (!RKLoadRepo(repoID, &error)) { RKPrintErr(@"源不存在：%@", error.localizedDescription); return 1; }
    NSString *destinationName = nil;
    if (!RKCopyDebIntoRepo(repoID, args[3], moveDeb, &destinationName, &error)) {
        RKPrintErr(@"%@ deb 失败：%@", moveDeb ? @"移动" : @"复制", error.localizedDescription);
        return 1;
    }
    if (!RKBuildRepo(repoID, &error)) { RKPrintErr(@"重建索引失败：%@", error.localizedDescription); return 1; }
    RKPrint(@"已%@导入：%@", moveDeb ? @"移动" : @"复制", destinationName ?: args[3].lastPathComponent);
    return 0;
}

static int RKCommandAddMany(NSArray<NSString *> *args) {
    if (args.count < 4) { RKPrintUsage(); return 2; }
    NSString *repoID = args[2];
    NSError *error = nil;
    if (!RKLoadRepo(repoID, &error)) { RKPrintErr(@"源不存在：%@", error.localizedDescription); return 1; }
    NSUInteger successCount = 0;
    NSMutableArray *failures = [NSMutableArray array];
    for (NSUInteger index = 3; index < args.count; index++) {
        NSString *path = args[index];
        if ([path hasPrefix:@"--"]) continue;
        NSString *destinationName = nil;
        NSError *itemError = nil;
        if (RKCopyDebIntoRepo(repoID, path, NO, &destinationName, &itemError)) {
            successCount++;
            RKPrint(@"已复制：%@", destinationName ?: path.lastPathComponent);
        } else {
            NSString *message = [NSString stringWithFormat:@"跳过：%@，%@", path.lastPathComponent ?: path, itemError.localizedDescription ?: @"导入失败"];
            [failures addObject:message];
            RKPrint(@"%@", message);
        }
    }
    if (!successCount) {
        RKPrintErr(@"批量导入失败：没有可导入的 deb");
        return 1;
    }
    if (!RKBuildRepo(repoID, &error)) { RKPrintErr(@"重建索引失败：%@", error.localizedDescription); return 1; }
    RKPrint(@"导入完成：%lu 个成功，%lu 个失败", (unsigned long)successCount, (unsigned long)failures.count);
    return failures.count ? 0 : 0;
}

static int RKCommandInspectDeb(NSArray<NSString *> *args) {
    if (args.count < 3) { RKPrintUsage(); return 2; }
    NSString *path = RKNormalizedExistingPath(args[2]);
    NSError *error = nil;
    NSDictionary *info = RKDebControlInfoAtPath(path, &error);
    if (!info) { RKPrintErr(@"读取 deb 失败：%@", error.localizedDescription); return 1; }
    NSDictionary *fields = info[@"fields"];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"control"] = fields ?: @{};
    result[@"controlOrder"] = info[@"order"] ?: @[];
    result[@"package"] = RKStringValue(fields[@"Package"]);
    result[@"name"] = RKPackageDisplayName(fields ?: @{});
    result[@"version"] = RKStringValue(fields[@"Version"]);
    result[@"architecture"] = RKStringValue(fields[@"Architecture"]);
    result[@"section"] = RKStringValue(fields[@"Section"]);
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    RKPrint(@"%@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    return 0;
}

static int RKCommandInstalled(NSArray<NSString *> *args) {
    (void)args;
    int exitCode = 0;
    NSString *format = @"${Package}\t${Version}\t${Architecture}\t${Section}\t${binary:Summary}\n";
    NSString *output = RKRunCommandCapture(@"/usr/bin/dpkg-query", @[@"-W", @"-f", format], nil, YES, &exitCode, nil);
    if (exitCode != 0 || !output) {
        RKPrintErr(@"读取已安装软件包失败：%@", output.length ? output : @"缺少 dpkg-query，请安装 dpkg");
        return 1;
    }
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *line in [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if (!line.length) continue;
        NSArray *parts = [line componentsSeparatedByString:@"\t"];
        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        item[@"package"] = parts.count > 0 ? parts[0] : @"";
        item[@"version"] = parts.count > 1 ? parts[1] : @"";
        item[@"architecture"] = parts.count > 2 ? parts[2] : @"";
        item[@"section"] = parts.count > 3 ? parts[3] : @"";
        item[@"summary"] = parts.count > 4 ? [[parts subarrayWithRange:NSMakeRange(4, parts.count - 4)] componentsJoinedByString:@" "] : @"";
        if ([item[@"package"] length]) [items addObject:item];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:items options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    RKPrint(@"%@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    return 0;
}


static NSString *RKSafeDebFileComponent(NSString *value) {
    NSString *source = RKStringValue(value);
    if (!source.length) return @"unknown";
    NSMutableString *result = [NSMutableString stringWithCapacity:source.length];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.+-~_"];
    for (NSUInteger index = 0; index < source.length; index++) {
        unichar character = [source characterAtIndex:index];
        if ([allowed characterIsMember:character]) [result appendFormat:@"%C", character];
        else [result appendString:@"_"];
    }
    return result.length ? result : @"unknown";
}

static NSDictionary<NSString *, NSString *> *RKInstalledPackageStatusFields(NSString *packageID, NSError **error) {
    int exitCode = 0;
    NSString *output = RKRunCommandCapture(@"/usr/bin/dpkg-query", @[@"-s", packageID], nil, YES, &exitCode, error);
    if (exitCode != 0 || !output.length) {
        RKSetError(error, exitCode ?: 1, RKCommandFailureMessage(@"dpkg-query -s", exitCode, output));
        return nil;
    }
    NSDictionary *stanza = RKParseControlStanzasWithOrder(output).firstObject;
    NSDictionary *fields = [stanza[@"fields"] isKindOfClass:[NSDictionary class]] ? stanza[@"fields"] : nil;
    if (!fields.count) {
        RKSetError(error, 30, [NSString stringWithFormat:@"无法读取已安装包信息：%@", packageID]);
        return nil;
    }
    NSMutableDictionary *control = [fields mutableCopy];
    for (NSString *key in @[@"Status", @"Conffiles", @"Config-Version"]) [control removeObjectForKey:key];
    if (!RKStringValue(control[@"Package"]).length) control[@"Package"] = packageID;
    if (!RKStringValue(control[@"Maintainer"]).length) control[@"Maintainer"] = @"DaFei";
    if (!RKStringValue(control[@"Section"]).length) control[@"Section"] = @"Tweaks";
    if (!RKStringValue(control[@"Description"]).length) control[@"Description"] = RKStringValue(control[@"Name"]).length ? control[@"Name"] : control[@"Package"];
    for (NSString *required in @[@"Package", @"Version", @"Architecture", @"Description"]) {
        if (!RKStringValue(control[required]).length) {
            RKSetError(error, 31, [NSString stringWithFormat:@"已安装包 %@ 缺少字段：%@", packageID, required]);
            return nil;
        }
    }
    return control;
}

static NSArray<NSString *> *RKInstalledPackageFileList(NSString *packageID, NSError **error) {
    int exitCode = 0;
    NSString *output = RKRunCommandCapture(@"/usr/bin/dpkg-query", @[@"-L", packageID], nil, YES, &exitCode, error);
    if (exitCode != 0 || !output.length) {
        RKSetError(error, exitCode ?: 1, RKCommandFailureMessage(@"dpkg-query -L", exitCode, output));
        return nil;
    }
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (NSString *line in [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *path = [line stringByTrimmingCharactersInSet:whitespace];
        if (!path.length || [path isEqualToString:@"."] || ![path hasPrefix:@"/"]) continue;
        struct stat info;
        if (lstat(path.fileSystemRepresentation, &info) != 0) continue;
        if (S_ISDIR(info.st_mode)) continue;
        if (S_ISREG(info.st_mode) || S_ISLNK(info.st_mode)) [files addObject:path];
    }
    return files;
}

static BOOL RKWriteInstalledPackageControl(NSDictionary *fields, NSString *debianDir, NSError **error) {
    NSMutableDictionary *control = [fields mutableCopy];
    for (NSString *key in @[@"Status", @"Conffiles", @"Config-Version"]) [control removeObjectForKey:key];
    NSString *text = RKControlTextFromFields(control);
    NSString *controlPath = [debianDir stringByAppendingPathComponent:@"control"];
    if (![text writeToFile:controlPath atomically:YES encoding:NSUTF8StringEncoding error:error]) return NO;
    chmod(controlPath.fileSystemRepresentation, 0644);
    return YES;
}

static NSArray<NSString *> *RKDpkgInfoDirectoryCandidates(void) {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    for (NSString *path in @[@"/var/jb/var/lib/dpkg/info", RKRealPath(@"/var/lib/dpkg/info"), @"/var/lib/dpkg/info"]) {
        if (path.length && ![candidates containsObject:path]) [candidates addObject:path];
    }
    return candidates;
}

static void RKCopyInstalledPackageMaintainerFiles(NSString *packageID, NSString *debianDir, NSMutableArray<NSString *> *warnings) {
    NSDictionary<NSString *, NSNumber *> *metadata = @{
        @"preinst": @0755,
        @"postinst": @0755,
        @"prerm": @0755,
        @"postrm": @0755,
        @"triggers": @0644,
        @"conffiles": @0644
    };
    NSArray *infoDirs = RKDpkgInfoDirectoryCandidates();
    for (NSString *name in metadata) {
        NSString *source = nil;
        for (NSString *infoDir in infoDirs) {
            NSString *candidate = [infoDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", packageID, name]];
            if ([RKFileManager() fileExistsAtPath:candidate]) { source = candidate; break; }
        }
        if (!source.length) continue;
        if (access(source.fileSystemRepresentation, R_OK) != 0) {
            [warnings addObject:[NSString stringWithFormat:@"%@：跳过不可读维护文件 %@", packageID, source]];
            continue;
        }
        NSString *destination = [debianDir stringByAppendingPathComponent:name];
        [RKFileManager() removeItemAtPath:destination error:nil];
        NSError *copyError = nil;
        if (![RKFileManager() copyItemAtPath:source toPath:destination error:&copyError]) {
            [warnings addObject:[NSString stringWithFormat:@"%@：复制维护文件失败 %@：%@", packageID, source, copyError.localizedDescription ?: @""]];
            continue;
        }
        chmod(destination.fileSystemRepresentation, metadata[name].unsignedShortValue);
    }
}

static BOOL RKCopySymlinkPayload(NSString *source, NSString *destination, NSMutableArray<NSString *> *warnings, NSString *packageID) {
    char target[PATH_MAX];
    ssize_t length = readlink(source.fileSystemRepresentation, target, sizeof(target) - 1);
    if (length < 0) {
        [warnings addObject:[NSString stringWithFormat:@"%@：读取符号链接失败 %@", packageID, source]];
        return NO;
    }
    target[length] = '\0';
    [RKFileManager() removeItemAtPath:destination error:nil];
    if (symlink(target, destination.fileSystemRepresentation) != 0) {
        [warnings addObject:[NSString stringWithFormat:@"%@：创建符号链接失败 %@", packageID, destination]];
        return NO;
    }
    return YES;
}

static NSUInteger RKCopyInstalledPackagePayload(NSString *packageID, NSArray<NSString *> *files, NSString *buildRoot, NSMutableArray<NSString *> *warnings) {
    NSUInteger copiedCount = 0;
    for (NSString *source in files) {
        struct stat info;
        if (lstat(source.fileSystemRepresentation, &info) != 0) {
            [warnings addObject:[NSString stringWithFormat:@"%@：跳过不存在文件 %@", packageID, source]];
            continue;
        }
        NSString *relative = [source hasPrefix:@"/"] ? [source substringFromIndex:1] : source;
        if (!relative.length) continue;
        NSString *destination = [buildRoot stringByAppendingPathComponent:relative];
        NSError *error = nil;
        if (!RKEnsureDirectory(destination.stringByDeletingLastPathComponent, &error)) {
            [warnings addObject:[NSString stringWithFormat:@"%@：创建目录失败 %@：%@", packageID, destination.stringByDeletingLastPathComponent, error.localizedDescription ?: @""]];
            continue;
        }
        if (S_ISLNK(info.st_mode)) {
            if (RKCopySymlinkPayload(source, destination, warnings, packageID)) copiedCount++;
            continue;
        }
        if (!S_ISREG(info.st_mode)) {
            [warnings addObject:[NSString stringWithFormat:@"%@：跳过非普通文件 %@", packageID, source]];
            continue;
        }
        if (access(source.fileSystemRepresentation, R_OK) != 0) {
            [warnings addObject:[NSString stringWithFormat:@"%@：跳过不可读文件 %@", packageID, source]];
            continue;
        }
        [RKFileManager() removeItemAtPath:destination error:nil];
        if (![RKFileManager() copyItemAtPath:source toPath:destination error:&error]) {
            [warnings addObject:[NSString stringWithFormat:@"%@：复制文件失败 %@：%@", packageID, source, error.localizedDescription ?: @""]];
            continue;
        }
        chmod(destination.fileSystemRepresentation, info.st_mode & 07777);
        copiedCount++;
    }
    return copiedCount;
}

static BOOL RKBuildInstalledPackageDeb(NSString *packageID, NSString *repoID, NSString **destinationName, NSMutableArray<NSString *> *warnings, NSError **error) {
    NSDictionary *fields = RKInstalledPackageStatusFields(packageID, error);
    if (!fields) return NO;
    NSArray *files = RKInstalledPackageFileList(packageID, error);
    if (!files) return NO;

    NSString *workDir = RKTemporaryDirectory(@"repokit-installed-repack", error);
    if (!workDir) return NO;
    @try {
        NSString *buildRoot = [workDir stringByAppendingPathComponent:@"build"];
        NSString *debianDir = [buildRoot stringByAppendingPathComponent:@"DEBIAN"];
        if (!RKEnsureDirectory(debianDir, error)) return NO;
        if (!RKWriteInstalledPackageControl(fields, debianDir, error)) return NO;
        RKCopyInstalledPackageMaintainerFiles(packageID, debianDir, warnings);
        NSUInteger copiedCount = RKCopyInstalledPackagePayload(packageID, files, buildRoot, warnings);
        if (!copiedCount) {
            RKSetError(error, 32, [NSString stringWithFormat:@"%@ 没有可复制的文件", packageID]);
            return NO;
        }

        NSString *fileName = [NSString stringWithFormat:@"%@_%@_%@.deb",
                              RKSafeDebFileComponent(fields[@"Package"]),
                              RKSafeDebFileComponent(fields[@"Version"]),
                              RKSafeDebFileComponent(fields[@"Architecture"])] ;
        NSString *debPath = [workDir stringByAppendingPathComponent:fileName];
        int exitCode = 0;
        NSString *output = RKRunCommand(@"/usr/bin/dpkg-deb", @[@"--build", @"--root-owner-group", buildRoot, debPath], nil, &exitCode, error);
        if (exitCode != 0 || !output) {
            RKSetError(error, exitCode ?: 1, RKCommandFailureMessage(@"dpkg-deb", exitCode, output));
            return NO;
        }
        return RKCopyDebIntoRepo(repoID, debPath, NO, destinationName, error);
    } @finally {
        [RKFileManager() removeItemAtPath:workDir error:nil];
    }
}

static int RKCommandRepackInstalled(NSArray<NSString *> *args) {
    if (args.count < 4) { RKPrintUsage(); return 2; }
    NSString *repoID = args[2];
    NSError *error = nil;
    if (!RKLoadRepo(repoID, &error)) { RKPrintErr(@"源不存在：%@", error.localizedDescription); return 1; }

    NSUInteger successCount = 0;
    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    NSMutableArray<NSString *> *warnings = [NSMutableArray array];
    NSMutableArray<NSString *> *importedNames = [NSMutableArray array];

    for (NSUInteger index = 3; index < args.count; index++) {
        NSString *packageID = args[index];
        if (!packageID.length) continue;
        NSError *itemError = nil;
        NSString *destinationName = nil;
        if (RKBuildInstalledPackageDeb(packageID, repoID, &destinationName, warnings, &itemError)) {
            successCount++;
            [importedNames addObject:destinationName ?: packageID];
        } else {
            [failures addObject:[NSString stringWithFormat:@"%@: %@", packageID, itemError.localizedDescription ?: @"重建 deb 失败"]];
        }
    }

    if (!successCount) {
        RKPrintErr(@"已安装软件包导入失败：%@", failures.count ? [failures componentsJoinedByString:@"\n"] : @"没有可导入的软件包");
        if (warnings.count) RKPrintErr(@"警告：%@", [warnings componentsJoinedByString:@"\n"]);
        return 1;
    }
    if (!RKBuildRepo(repoID, &error)) {
        RKPrintErr(@"重建索引失败：%@", error.localizedDescription);
        return 1;
    }
    RKPrint(@"已从已安装记录导入 %lu 个：%@", (unsigned long)successCount, [importedNames componentsJoinedByString:@", "]);
    if (failures.count) RKPrint(@"跳过 %lu 个：%@", (unsigned long)failures.count, [failures componentsJoinedByString:@"\n"]);
    if (warnings.count) RKPrint(@"警告：%@", [warnings componentsJoinedByString:@"\n"]);
    return 0;
}

static int RKCommandRescan(NSArray<NSString *> *args) {
    if (args.count < 3) { RKPrintUsage(); return 2; }
    NSError *error = nil;
    BOOL deepScan = RKHasFlag(args, @"--deep");
    if (!RKRescanRepo(args[2], deepScan, &error)) {
        RKPrintErr(@"重新扫描失败：%@", error.localizedDescription);
        return 1;
    }
    NSArray *packages = RKLoadPackages(args[2]);
    RKPrint(@"已%@：%lu 个 deb", deepScan ? @"深度扫描" : @"快速扫描", (unsigned long)packages.count);
    return 0;
}

static int RKCommandList(NSArray<NSString *> *args) {
    if (args.count < 3) { RKPrintUsage(); return 2; }
    RKRefreshPackagesCacheIfNeeded(args[2], RKPublicPath(args[2]), nil);
    NSArray *packages = RKLoadPackages(args[2]);
    NSData *data = [NSJSONSerialization dataWithJSONObject:packages options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    RKPrint(@"%@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    return 0;
}

static int RKCommandShow(NSArray<NSString *> *args) {
    if (args.count < 4) { RKPrintUsage(); return 2; }
    NSArray *packages = RKLoadPackages(args[2]);
    NSInteger index = RKIndexOfPackage(packages, args[3], args.count > 4 ? args[4] : nil);
    if (index == NSNotFound) { RKPrintErr(@"包不存在"); return 1; }
    NSData *data = [NSJSONSerialization dataWithJSONObject:packages[(NSUInteger)index] options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    RKPrint(@"%@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    return 0;
}

static int RKCommandEdit(NSArray<NSString *> *args) {
    if (args.count < 5) { RKPrintUsage(); return 2; }
    NSString *repoID = args[2];
    NSMutableArray *packages = RKLoadPackages(repoID);
    NSInteger index = RKIndexOfPackage(packages, args[3], args[4]);
    if (index == NSNotFound) { RKPrintErr(@"包不存在"); return 1; }
    NSMutableDictionary *record = [packages[(NSUInteger)index] mutableCopy];
    NSDictionary *mapping = @{
        @"--package": @"package",
        @"--name": @"name",
        @"--version": @"version",
        @"--architecture": @"architecture",
        @"--section": @"section",
        @"--description": @"description",
        @"--depends": @"depends",
        @"--pre-depends": @"preDepends",
        @"--maintainer": @"maintainer",
        @"--author": @"author",
        @"--depiction": @"depiction",
        @"--homepage": @"homepage",
        @"--icon": @"icon",
        @"--filename": @"filename",
        @"--size": @"size",
        @"--md5": @"md5",
        @"--sha256": @"sha256",
        @"--conflicts": @"conflicts",
        @"--replaces": @"replaces",
        @"--provides": @"provides",
        @"--tag": @"tag"
    };
    for (NSString *option in mapping) {
        NSString *value = RKOption(args, option, nil);
        if (value) {
            NSString *field = mapping[option];
            record[field] = [field isEqualToString:@"size"] ? @((unsigned long long)strtoull(value.UTF8String, NULL, 10)) : value;
        }
    }
    record[@"updatedAt"] = RKNowString();
    packages[(NSUInteger)index] = record;
    NSError *error = nil;
    if (!RKSavePackages(repoID, packages, &error)) { RKPrintErr(@"保存失败：%@", error.localizedDescription); return 1; }
    RKBuildRepo(repoID, nil);
    RKPrint(@"已更新包：%@ %@", args[3], args[4]);
    return 0;
}

static int RKCommandEditDeb(NSArray<NSString *> *args) {
    if (args.count < 5) { RKPrintUsage(); return 2; }
    NSError *error = nil;
    if (!RKEditDebPackage(args[2], args[3], args[4], args, &error)) {
        RKPrintErr(@"编辑 deb 失败：%@", error.localizedDescription);
        return 1;
    }
    RKPrint(@"已重打包并更新索引：%@ %@", args[3], args[4]);
    return 0;
}

static int RKCommandRemove(NSArray<NSString *> *args) {
    if (args.count < 4) { RKPrintUsage(); return 2; }
    NSString *repoID = args[2];
    NSString *package = args[3];
    NSString *version = args.count > 4 && ![args[4] hasPrefix:@"--"] ? args[4] : nil;
    if (!RKHasFlag(args, @"--delete-file")) {
        RKPrintErr(@"索引由 debs 目录生成；请使用 --delete-file 删除 deb 文件");
        return 1;
    }
    NSMutableArray *packages = RKLoadPackages(repoID);
    NSInteger index = RKIndexOfPackage(packages, package, version);
    if (index == NSNotFound) { RKPrintErr(@"包不存在"); return 1; }
    NSDictionary *record = packages[(NSUInteger)index];
    NSString *filename = record[@"filename"];
    if (filename.length) {
        NSString *path = [filename hasPrefix:@"/"] ? RKNormalizedExistingPath(filename) : [RKPublicPath(repoID) stringByAppendingPathComponent:filename];
        RKMoveItemToTrash(repoID, path, nil, nil);
    }
    [packages removeObjectAtIndex:(NSUInteger)index];
    NSError *error = nil;
    if (!RKSavePackages(repoID, packages, &error)) { RKPrintErr(@"保存失败：%@", error.localizedDescription); return 1; }
    if (!RKBuildRepo(repoID, &error)) { RKPrintErr(@"重建索引失败：%@", error.localizedDescription); return 1; }
    RKPrint(@"已删除 deb：%@", package);
    return 0;
}

static int RKCommandBuild(NSArray<NSString *> *args) {
    if (args.count < 3) { RKPrintUsage(); return 2; }
    NSError *error = nil;
    if (!RKBuildRepo(args[2], &error)) {
        RKPrintErr(@"构建失败：%@", error.localizedDescription);
        return 1;
    }
    RKPrint(@"构建完成：%@", [RKPublicPath(args[2]) stringByAppendingPathComponent:@"Packages.gz"]);
    return 0;
}

static int RKCommandCheck(NSArray<NSString *> *args) {
    if (args.count < 3) { RKPrintUsage(); return 2; }
    for (NSString *issue in RKCheckRepo(args[2])) RKPrint(@"%@", issue);
    return 0;
}

static int RKCommandGithub(NSArray<NSString *> *args) {
    if (args.count < 3) { RKPrintUsage(); return 2; }
    NSError *error = nil;
    NSMutableDictionary *repo = RKLoadRepo(args[2], &error);
    if (!repo) { RKPrintErr(@"读取源失败：%@", error.localizedDescription); return 1; }
    NSDictionary *existingGithub = [repo[@"github"] isKindOfClass:[NSDictionary class]] ? repo[@"github"] : @{};
    NSMutableDictionary *github = [existingGithub mutableCopy];
    NSString *remote = RKOption(args, @"--remote", nil);
    NSString *branch = RKOption(args, @"--branch", nil);
    NSString *user = RKOption(args, @"--user", nil);
    NSString *email = RKOption(args, @"--email", nil);
    if (remote) github[@"remote"] = remote;
    if (branch) github[@"branch"] = branch;
    if (user) github[@"user"] = user;
    if (email) github[@"email"] = email;
    github[@"auth"] = @"ssh";
    [github removeObjectForKey:@"token"];
    if (!github[@"branch"]) github[@"branch"] = @"main";
    repo[@"github"] = github;
    repo[@"updatedAt"] = RKNowString();
    if (!RKWriteJSON(repo, RKRepoJSONPath(args[2]), &error)) { RKPrintErr(@"保存 GitHub 配置失败：%@", error.localizedDescription); return 1; }
    RKPrint(@"已保存 GitHub SSH 配置");
    return 0;
}

static int RKCommandPush(NSArray<NSString *> *args) {
    if (args.count < 3) { RKPrintUsage(); return 2; }
    NSString *repoID = args[2];
    NSError *error = nil;
    NSDictionary *repo = RKLoadRepo(repoID, &error);
    if (!repo) { RKPrintErr(@"读取源失败：%@", error.localizedDescription); return 1; }
    NSDictionary *github = [repo[@"github"] isKindOfClass:[NSDictionary class]] ? repo[@"github"] : @{};
    NSString *remote = [github[@"remote"] isKindOfClass:[NSString class]] ? [github[@"remote"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
    NSString *branch = [github[@"branch"] isKindOfClass:[NSString class]] ? [github[@"branch"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"main";
    NSString *user = [github[@"user"] isKindOfClass:[NSString class]] ? github[@"user"] : @"";
    NSString *email = [github[@"email"] isKindOfClass:[NSString class]] ? github[@"email"] : @"";
    if (!branch.length) branch = @"main";
    if (!remote.length) { RKPrintErr(@"未配置 GitHub SSH remote"); return 1; }
    if (!RKIsSSHRemote(remote)) { RKPrintErr(@"请使用 SSH remote，例如 git@github.com:user/repo.git"); return 1; }
    if (!user.length) { RKPrintErr(@"未配置 GitHub 用户名"); return 1; }
    if (!email.length) { RKPrintErr(@"未配置 Git 提交邮箱"); return 1; }

    NSString *logicalSSHKeyPath = RKLogicalSSHKeyPath();
    NSString *realSSHKeyPath = RKRealSSHKeyPath();
    if (access(realSSHKeyPath.fileSystemRepresentation, R_OK) != 0) {
        RKPrintErr(@"未找到 SSH 私钥：%@\n请先执行：mkdir -p /var/mobile/.ssh && ssh-keygen -t ed25519 -f /var/mobile/.ssh/id_ed25519 -C \"you@example.com\"\n然后把 %@.pub 添加到 GitHub SSH keys", logicalSSHKeyPath, logicalSSHKeyPath);
        return 1;
    }
    NSString *sshExecutable = RKResolveExecutablePath(@"/usr/bin/ssh");
    if (!RKExecutableExistsAtPath(sshExecutable)) {
        RKPrintErr(@"未找到 ssh 客户端，请安装 openssh-client");
        return 1;
    }

    NSError *buildError = nil;
    if (!RKBuildRepo(repoID, &buildError)) {
        RKPrintErr(@"推送前构建索引失败：%@", buildError.localizedDescription ?: @"unknown error");
        return 1;
    }
    NSString *publicPath = RKPublicPath(repoID);
    NSString *sshWrapperPath = nil;
    if (!RKWriteSSHWrapper(repoID, sshExecutable, realSSHKeyPath, &sshWrapperPath, &error)) {
        RKPrintErr(@"写入 Git SSH wrapper 失败：%@", error.localizedDescription ?: @"unknown error");
        return 1;
    }
    NSDictionary *sshEnvironment = @{
        @"GIT_SSH": sshWrapperPath,
        @"GIT_SSH_COMMAND": @"",
        @"GIT_SSH_VARIANT": @"ssh",
        @"HOME": RKRealSSHHomePath()
    };
    int exitCode = 0;
    NSMutableString *log = [NSMutableString string];
    NSArray<NSDictionary *> *commands = @[
        @{@"args": @[@"-C", publicPath, @"init"]},
        @{@"args": @[@"-C", publicPath, @"checkout", @"-B", branch]},
        @{@"args": @[@"-C", publicPath, @"config", @"user.name", user]},
        @{@"args": @[@"-C", publicPath, @"config", @"user.email", email]},
        @{@"args": @[@"-C", publicPath, @"remote", @"remove", @"origin"], @"allowRemoteRemoveFailure": @YES},
        @{@"args": @[@"-C", publicPath, @"remote", @"add", @"origin", remote]},
        @{@"args": @[@"-C", publicPath, @"add", @"."]},
        @{@"args": @[@"-C", publicPath, @"commit", @"-m", RKOption(args, @"--message", @"Update RepoKit repository")], @"allowNothingToCommit": @YES},
        @{@"args": @[@"-C", publicPath, @"push", @"-u", @"origin", branch], @"environment": sshEnvironment}
    ];
    for (NSDictionary *command in commands) {
        NSArray<NSString *> *commandArgs = command[@"args"];
        NSArray<NSString *> *displayArgs = command[@"displayArgs"] ?: commandArgs;
        NSDictionary<NSString *, NSString *> *environment = [command[@"environment"] isKindOfClass:[NSDictionary class]] ? command[@"environment"] : nil;
        NSString *output = environment ? RKRunCommandWithEnvironment(@"/usr/bin/git", commandArgs, nil, environment, &exitCode, &error) : RKRunCommand(@"/usr/bin/git", commandArgs, nil, &exitCode, &error);
        [log appendFormat:@"$ git %@\n%@\n", [displayArgs componentsJoinedByString:@" "], output ?: error.localizedDescription ?: @""];
        if (exitCode != 0) {
            if ([command[@"allowRemoteRemoveFailure"] boolValue]) continue;
            if ([command[@"allowNothingToCommit"] boolValue] && [output containsString:@"nothing to commit"]) continue;
            RKPrintErr(@"Git 命令失败：git %@\n%@", [displayArgs componentsJoinedByString:@" "], output ?: @"");
            return 1;
        }
    }
    NSString *logDir = [[RKRepoPath(repoID) stringByAppendingPathComponent:@"logs"] stringByAppendingPathComponent:@"github.log"];
    [log writeToFile:logDir atomically:YES encoding:NSUTF8StringEncoding error:nil];
    RKPrint(@"已通过 SSH 推送 GitHub：%@ %@", remote, branch);
    return 0;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSMutableArray<NSString *> *args = [NSMutableArray array];
        for (int index = 0; index < argc; index++) {
            [args addObject:[NSString stringWithUTF8String:argv[index]] ?: @""];
        }
        RKEnsureDirectory([[RKRealDataRoot() stringByAppendingPathComponent:@"repos"] stringByStandardizingPath], nil);
        RKEnsureDirectory([[RKRealDataRoot() stringByAppendingPathComponent:@"logs"] stringByStandardizingPath], nil);
        if (args.count < 2 || [args[1] isEqualToString:@"help"] || [args[1] isEqualToString:@"--help"]) {
            RKPrintUsage();
            return 0;
        }
        NSString *command = args[1];
        if ([command isEqualToString:@"repos"]) return RKCommandRepos();
        if ([command isEqualToString:@"init"]) return RKCommandInit(args);
        if ([command isEqualToString:@"import-source"]) return RKCommandImportSource(args);
        if ([command isEqualToString:@"repo"]) return RKCommandRepo(args);
        if ([command isEqualToString:@"repo-edit"]) return RKCommandRepoEdit(args);
        if ([command isEqualToString:@"delete-repo"]) return RKCommandDeleteRepo(args);
        if ([command isEqualToString:@"add"]) return RKCommandAdd(args);
        if ([command isEqualToString:@"add-many"]) return RKCommandAddMany(args);
        if ([command isEqualToString:@"inspect-deb"]) return RKCommandInspectDeb(args);
        if ([command isEqualToString:@"installed"]) return RKCommandInstalled(args);
        if ([command isEqualToString:@"repack-installed"]) return RKCommandRepackInstalled(args);
        if ([command isEqualToString:@"rescan"]) return RKCommandRescan(args);
        if ([command isEqualToString:@"list"]) return RKCommandList(args);
        if ([command isEqualToString:@"show"]) return RKCommandShow(args);
        if ([command isEqualToString:@"edit"]) return RKCommandEdit(args);
        if ([command isEqualToString:@"edit-deb"]) return RKCommandEditDeb(args);
        if ([command isEqualToString:@"remove"]) return RKCommandRemove(args);
        if ([command isEqualToString:@"build"]) return RKCommandBuild(args);
        if ([command isEqualToString:@"check"]) return RKCommandCheck(args);
        if ([command isEqualToString:@"github"]) return RKCommandGithub(args);
        if ([command isEqualToString:@"push"]) return RKCommandPush(args);
        RKPrintUsage();
        return 2;
    }
}
