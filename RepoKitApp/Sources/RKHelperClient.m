#import "RKHelperClient.h"
#import <roothide.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

@implementation RKHelperResult
@end

@implementation RKHelperClient

+ (instancetype)sharedClient {
    static RKHelperClient *client;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        client = [[RKHelperClient alloc] init];
    });
    return client;
}

- (RKHelperResult *)runArguments:(NSArray<NSString *> *)arguments {
    RKHelperResult *result = [[RKHelperResult alloc] init];
    NSString *logicalExecutable = @"/usr/bin/repokit-helper";
    NSString *realExecutable = jbroot(logicalExecutable);
    int stdoutPipe[2];
    if (pipe(stdoutPipe) != 0) {
        result.exitCode = errno;
        result.output = @"pipe failed";
        return result;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, stdoutPipe[0]);
    posix_spawn_file_actions_addclose(&actions, stdoutPipe[1]);

    NSUInteger count = arguments.count + 2;
    char **argv = calloc(count, sizeof(char *));
    argv[0] = (char *)logicalExecutable.UTF8String;
    for (NSUInteger index = 0; index < arguments.count; index++) {
        argv[index + 1] = (char *)arguments[index].UTF8String;
    }
    argv[count - 1] = NULL;

    pid_t pid = 0;
    int spawnResult = posix_spawn(&pid, realExecutable.fileSystemRepresentation, &actions, NULL, argv, environ);
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
        result.exitCode = spawnResult;
        result.output = [NSString stringWithFormat:@"spawn failed: %@", realExecutable];
        return result;
    }

    int status = 0;
    waitpid(pid, &status, 0);
    result.exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : status;
    result.output = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding] ?: @"";
    return result;
}

- (id)JSONObjectFromResult:(RKHelperResult *)result fallback:(id)fallback {
    if (result.exitCode != 0 || !result.output.length) return fallback;
    NSData *data = [result.output dataUsingEncoding:NSUTF8StringEncoding];
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return object ?: fallback;
}

- (NSArray<NSDictionary *> *)repos {
    id object = [self JSONObjectFromResult:[self runArguments:@[@"repos"]] fallback:@[]];
    return [object isKindOfClass:[NSArray class]] ? object : @[];
}

- (NSDictionary *)repoWithID:(NSString *)repoID {
    if (!repoID.length) return nil;
    id object = [self JSONObjectFromResult:[self runArguments:@[@"repo", repoID]] fallback:nil];
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

- (NSArray<NSDictionary *> *)packagesForRepoID:(NSString *)repoID {
    if (!repoID.length) return @[];
    id object = [self JSONObjectFromResult:[self runArguments:@[@"list", repoID]] fallback:@[]];
    return [object isKindOfClass:[NSArray class]] ? object : @[];
}

@end
