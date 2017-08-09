//
//  MPAgentUp2DateController.m
/*
 Copyright (c) 2017, Lawrence Livermore National Security, LLC.
 Produced at the Lawrence Livermore National Laboratory (cf, DISCLAIMER).
 Written by Charles Heizer <heizer1 at llnl.gov>.
 LLNL-CODE-636469 All rights reserved.
 
 This file is part of MacPatch, a program for installing and patching
 software.
 
 MacPatch is free software; you can redistribute it and/or modify it under
 the terms of the GNU General Public License (as published by the Free
 Software Foundation) version 2, dated June 1991.
 
 MacPatch is distributed in the hope that it will be useful, but WITHOUT ANY
 WARRANTY; without even the IMPLIED WARRANTY OF MERCHANTABILITY or FITNESS
 FOR A PARTICULAR PURPOSE. See the terms and conditions of the GNU General Public
 License for more details.
 
 You should have received a copy of the GNU General Public License along
 with MacPatch; if not, write to the Free Software Foundation, Inc.,
 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA
 */

#import "MPAgentUp2DateController.h"
#import "MacPatch.h"

#define DEFAULT_TIMEOUT_VALUE 1800.0 // 30 Minutes

NSInteger const TaskErrorTimedOut = 900001;

@interface MPAgentUp2DateController ()

@property (nonatomic, assign) BOOL useMigrationConfig;
@property (nonatomic, assign) BOOL verifyFingerprint;
@property (nonatomic, strong) NSString *fingerprint;

- (NSDictionary *)collectVersionInfo;
- (BOOL)compareVersionStrings:(NSString *)leftVersion operator:(NSString *)aOp compareTo:(NSString *)rightVersion;
- (NSString *)downloadUpdate:(NSString *)aURL error:(NSError **)err;
- (NSString *)createTempDirFromURL:(NSString *)aURL;
- (int)unzip:(NSString *)aZipFilePath error:(NSError **)err;
- (int)unzip:(NSString *)aZipFilePath targetPath:(NSString *)aTargetPath error:(NSError **)err;
- (NSString *)runTask:(NSString *)aBinPath binArgs:(NSArray *)aArgs error:(NSError **)err;
- (NSString *)runTask:(NSString *)aBinPath binArgs:(NSArray *)aArgs environment:(NSDictionary *)aEnv error:(NSError **)err;
- (int)installPkg:(NSString *)pkgPath error:(NSError **)err;
- (int)installPkg:(NSString *)pkgPath target:(NSString *)aTarget error:(NSError **)err;
- (NSString *)installPkgWithResult:(NSString *)pkgPath target:(NSString *)aTarget error:(NSError **)err;

- (void)taskTimeoutThread;
- (void)taskTimeout:(NSNotification *)aNotification;

- (BOOL)scanForMigrationConfig;
- (MPNetServer *)migrationServerConfig;

- (NSData *)getRequestWithURIforREST:(NSString *)aURI error:(NSError **)err;
- (id)restGetRequestforURI:(NSString *)aURI resultType:(NSString *)resType error:(NSError **)err;
- (id)returnRequestWithType:(NSData *)requestData resultType:(NSString *)resultType error:(NSError **)err;
- (NSDictionary *)getAgentUpdates:(NSString *)curAppVersion build:(NSString *)curBuildVersion error:(NSError **)err;

@end

@implementation MPAgentUp2DateController

@synthesize _cuuid;
@synthesize _appPid;
@synthesize _updateData;
@synthesize _osVerDictionary;
@synthesize _migrationPlist;

@synthesize taskTimeoutTimer;
@synthesize taskTimeoutValue;
@synthesize taskTimedOut;
@synthesize useMigrationConfig;
@synthesize verifyFingerprint;
@synthesize fingerprint;

- (id)init
{
    self = [super init];
    if (self)
    {
		[self set_cuuid:[MPSystemInfo clientUUID]];
		[self set_updateData:nil];
        [self set_osVerDictionary:[MPSystemInfo osVersionOctets]];
        [self set_migrationPlist:[NSString stringWithFormat:@"%@/.migration.plist",MP_ROOT_UPDATE]];
        
        [self setTaskTimeoutValue:DEFAULT_TIMEOUT_VALUE];
        [self setTaskTimedOut:NO];
        [self setUseMigrationConfig:NO];
        [self setVerifyFingerprint:NO];
        
        mpAsus = [[MPAsus alloc] init];
        mpDataMgr = [[MPDataMgr alloc] init];
    }
    return self;    
}

-(int)scanForUpdate
{
	// Get local application versions
	logit(lcl_vInfo,@"Collecting agent version information.");	
	NSDictionary *_agentInfo = [self collectVersionInfo];
    
    BOOL isMigration = NO;
    isMigration = [self scanForMigrationConfig];
    
    NSError *wsErr = nil;
    NSDictionary *updateInfo;

    if (isMigration)
    {
        logit(lcl_vInfo,@"Migration plist was found, using alt settings.");
        updateInfo = [self getAgentUpdates:[_agentInfo objectForKey:@"agentVersion"] build:[_agentInfo objectForKey:@"agentBuild"] error:&wsErr];
    } else {
        MPWebServices *mpws = [[MPWebServices alloc] init];
        updateInfo = [mpws getAgentUpdates:[_agentInfo objectForKey:@"agentVersion"] build:[_agentInfo objectForKey:@"agentBuild"] error:&wsErr];
        if (wsErr) {
            logit(lcl_vError,@"%@, error code %d (%@)",[wsErr localizedDescription], (int)[wsErr code], [wsErr domain]);
            return 0;
        }
    }
    if (![updateInfo isKindOfClass:[NSDictionary class]])
    {
        logit(lcl_vError,@"Agent updater info is not available.");
        return 0;
    }

	logit(lcl_vDebug,@"WS Result: %@",updateInfo);
	logit(lcl_vInfo,@"Evaluate local versions for updates.");
	// See if the update is needed
	int needsUpdate = 0;
	if ([[updateInfo objectForKey:@"updateAvailable"] boolValue] == YES) {
        needsUpdate++;
	}
	
	if (needsUpdate >= 1) {
		logit(lcl_vInfo,@"Client agent needs updating, a newer version exists.");
	} else {
		logit(lcl_vInfo,@"Client agent is up to date.");
	}
	
	[self set_updateData:updateInfo];
	return needsUpdate;
}

-(void)scanAndUpdate
{
	int needsUpdate = 0; 
	if (_updateData == nil) {
		needsUpdate = [self scanForUpdate];
	}
	
	if (needsUpdate <= 0) {
		logit(lcl_vInfo,@"No update needed.");
		return;
	}

	logit(lcl_vInfo,@"Update needed.");
	NSError *err = nil;
	NSString *installResult;
	
	
	// Build the download String
	NSString *_dlURL = [_updateData objectForKey:@"pkg_url"];
	logit(lcl_vInfo,@"Download update package from: %@",_dlURL);
	
	// Download the File
	NSString *dlZipFile = [self downloadUpdate:_dlURL error:&err];
	logit(lcl_vDebug,@"dlZipFile Result:%@",dlZipFile);
	if (err) {
		logit(lcl_vError,@"Error downloading zip file, error code %d (%@)",(int)[err code], [err domain]);
		return;
	}
	
	logit(lcl_vInfo,@"Unzip package.");
	err = nil; //Reset the error
	[self unzip:dlZipFile error:&err];
	if (err) {
		logit(lcl_vError,@"Error unzip file, error code %d (%@)",(int)[err code], [err domain]);
		return;
	}
	logit(lcl_vInfo,@"Locate package(s) to install.");
	// Get the pkg to install
	NSString *pkgPath;
	NSString *pkgBaseDir = [dlZipFile stringByDeletingLastPathComponent];
	NSPredicate *pkgPredicate = [NSPredicate predicateWithFormat:@"(SELF like [cd] '*.pkg') OR (SELF like [cd] '*.mpkg')"];
	NSArray *pkgList = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:[dlZipFile stringByDeletingLastPathComponent] error:NULL] filteredArrayUsingPredicate:pkgPredicate];
	
	// Install pkg(s)
	for (int i = 0; i < [pkgList count]; i++)
	{	
		pkgPath = [NSString stringWithFormat:@"%@/%@",pkgBaseDir,[pkgList objectAtIndex:i]];
		logit(lcl_vInfo,@"Start install of %@",pkgPath);
		err = nil;
		installResult = [self installPkgWithResult:pkgPath target:@"/" error:&err];
		if (err) {	
			logit(lcl_vError,@"Error installing package, error code %d (%@)",(int)[err code], [err domain]);
			break;
		}
		logit(lcl_vInfo,@"%@",installResult);
        if (useMigrationConfig) {
            // Remove Migration Plist after successful install
            logit(lcl_vInfo,@"Remove Migration Plist after successful install.");
            err = nil;
            [[NSFileManager defaultManager] removeItemAtPath:_migrationPlist error:&err];
            if (err) {
                logit(lcl_vError,@"Error removing migration plist. %@",err.localizedDescription);
            }
        }
	}
	
}

#pragma mark -
#pragma mark Private

-(NSDictionary *)collectVersionInfo
{
	NSDictionary *_agentVersionInfo = [NSDictionary dictionaryWithContentsOfFile:AGENT_VER_PLIST];
	NSDictionary *_agentFrameWorkInfo = [NSDictionary dictionaryWithContentsOfFile:AGENT_FRAMEWORK_PATH];
	NSMutableDictionary *tmpDict = [[NSMutableDictionary alloc] init];
	
    //if ([_agentVersionInfo objectForKey:@"major"] && [_agentVersionInfo objectForKey:@"minor"] && [_agentVersionInfo objectForKey:@"bug"]) {
    //    NSString *_ver = [NSString stringWithFormat:@"%@.%@.%@",[_agentVersionInfo objectForKey:@"major"], [_agentVersionInfo objectForKey:@"minor"],[_agentVersionInfo objectForKey:@"bug"]];
   //     [tmpDict setObject:_ver forKey:@"agentVersion"];
    
    if ([_agentVersionInfo objectForKey:@"version"]) {
        [tmpDict setObject:[_agentVersionInfo objectForKey:@"version"] forKey:@"agentVersion"];
	} else {
		[tmpDict setObject:@"0" forKey:@"agentVersion"];
	}
	if ([_agentVersionInfo objectForKey:@"build"] ) {
		[tmpDict setObject:[_agentVersionInfo objectForKey:@"build"] forKey:@"agentBuild"];
	} else {
		[tmpDict setObject:@"0" forKey:@"agentBuild"];
	}
	if ([_agentFrameWorkInfo objectForKey:@"CFBundleShortVersionString"]) {
		[tmpDict setObject:[_agentFrameWorkInfo objectForKey:@"CFBundleShortVersionString"] forKey:@"agentFramework"];
	} else {
		[tmpDict setObject:@"0" forKey:@"agentFramework"];
	}
	
	NSDictionary *_appVersions = [NSDictionary dictionaryWithDictionary:tmpDict];
	
	return _appVersions; 
}

-(BOOL)compareVersionStrings:(NSString *)leftVersion operator:(NSString *)aOp compareTo:(NSString *)rightVersion
{
	BOOL fileVerPass = FALSE;
	int i;
	
	// Break version into fields (separated by '.')
	NSMutableArray *leftFields  = [[NSMutableArray alloc] initWithArray:[leftVersion  componentsSeparatedByString:@"."]];
	NSMutableArray *rightFields = [[NSMutableArray alloc] initWithArray:[rightVersion componentsSeparatedByString:@"."]];
	
	// Implict ".0" in case version doesn't have the same number of '.'
	if ([leftFields count] < [rightFields count]) {
		while ([leftFields count] != [rightFields count]) {
			[leftFields addObject:@"0"];
		}
	} else if ([leftFields count] > [rightFields count]) {
		while ([leftFields count] != [rightFields count]) {
			[rightFields addObject:@"0"];
		}
	}
	
	// Do a numeric comparison on each field
	NSComparisonResult result = NSOrderedSame;
	for(i = 0; i < [leftFields count]; i++) {
		result = [[leftFields objectAtIndex:i] compare:[rightFields objectAtIndex:i] options:NSNumericSearch];
		if (result != NSOrderedSame) {
			break;
		}
	}
	
	/*
	 * compareVersions(@"10.4",             @"10.3")             returns NSOrderedDescending (1)
	 * compareVersions(@"10.5",             @"10.5.0")           returns NSOrderedSame (0)
	 * compareVersions(@"10.4 Build 8L127", @"10.4 Build 8P135") returns NSOrderedAscending (-1)
	 */
	
	NSString *op = [aOp	uppercaseString];
	
	if ([op isEqualToString:@"EQ"] || [op isEqualToString:@"="] || [op isEqualToString:@"=="] ) 
	{
		if ( result == NSOrderedSame ) {
			fileVerPass = YES; goto done;
		} else {
			fileVerPass = NO; goto done;
		}
	}
	else if ([op isEqualToString:@"NEQ"] || [op isEqualToString:@"!="] || [op isEqualToString:@"=!"]) 
	{
		if ( result == NSOrderedSame ) {
			fileVerPass = NO; goto done;
		} else {
			fileVerPass = YES; goto done;
		}
		
	}
	else if ([op isEqualToString:@"LT"] || [op isEqualToString:@"<"]) 
	{
		if ( result == NSOrderedAscending ) {
			fileVerPass = YES; goto done;
		} else {
			fileVerPass = NO; goto done;
		}
	}
	else if ([op isEqualToString:@"LTE"] || [op isEqualToString:@"<="]) 
	{
		if ( result == NSOrderedAscending || result == NSOrderedSame ) {
			fileVerPass = YES; goto done;
		} else {
			fileVerPass = NO; goto done;
		}
	}
	else if ([op isEqualToString:@"GT"] || [op isEqualToString:@">"]) 
	{
		if ( result == NSOrderedDescending ) {
			fileVerPass = YES; goto done;
		} else {
			fileVerPass = NO; goto done;
		}
	}
	else if ([op isEqualToString:@"GTE"] || [op isEqualToString:@">="]) 
	{
		if ( result == NSOrderedDescending || result == NSOrderedSame ) {
			fileVerPass = YES; goto done;
		} else {
			fileVerPass = NO; goto done;
		}
	}
	
	
done:
	;
	return fileVerPass;
}

-(NSString *)downloadUpdate:(NSString *)aURL error:(NSError **)err
{
    NSString *res = nil;
    MPNetConfig *mpNetConfig;
    BOOL isMigration = NO;
    isMigration = [self scanForMigrationConfig];
    
    if (isMigration) {
        MPNetServer *_server = [self migrationServerConfig];
        if (!_server) {
            qlerror(@"Migration server info is nil, no download can happen.");
            return res;
        }
        mpNetConfig = [[MPNetConfig alloc] initWithServer:_server];
    } else {
        mpNetConfig = [[MPNetConfig alloc] init];
    }
    
    NSArray *servers = [mpNetConfig servers];
    NSURLResponse *response;
    MPNetRequest *req;
    NSURLRequest *urlReq;
    NSError *error = nil;
    
    for (MPNetServer *srv in servers)
    {
        qlinfo(@"Trying Server %@",srv.host);
        req = [[MPNetRequest alloc] initWithMPServer:srv];
        urlReq = [req buildDownloadRequest:aURL];
        error = nil;
        if (urlReq)
        {
            res = [req downloadFileRequest:urlReq returningResponse:&response error:&error];
            if (error) {
                if (err != NULL) {
                    *err = error;
                }
                qlerror(@"[%@][%d](%@ %d): %@",srv.host,(int)srv.port,error.domain,(int)error.code,error.localizedDescription);
                continue;
            }
            // Make any previouse error pointers nil, now that we have a valid host/connection
            if (err != NULL) {
                *err = nil;
            }
            break;
        } else {
            NSDictionary *userInfo = [NSDictionary dictionaryWithObject:@"NSURLRequest was nil." forKey:NSLocalizedDescriptionKey];
            error = [NSError errorWithDomain:NSOSStatusErrorDomain code:-1001 userInfo:userInfo];
            qlerror(@"%@",error.localizedDescription);
            if (err != NULL) {
                *err = error;
            }
            continue;
        }
    }

    return res;
}

-(NSString *)createTempDirFromURL:(NSString *)aURL
{
	NSString *tempFilePath;
	
	NSString *appName = [[NSProcessInfo processInfo] processName];
	NSString *tempDirectoryTemplate = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.XXXXXX",appName]];
	
	const char *tempDirectoryTemplateCString = [tempDirectoryTemplate fileSystemRepresentation];
	char *tempDirectoryNameCString = (char *)malloc(strlen(tempDirectoryTemplateCString) + 1);
	strcpy(tempDirectoryNameCString, tempDirectoryTemplateCString);
	char *result = mkdtemp(tempDirectoryNameCString);
	if (!result) {
		// handle directory creation failure
        free(tempDirectoryNameCString);
		logit(lcl_vError,@"Error, trying to create tmp directory.");
        return [@"/private/tmp" stringByAppendingPathComponent:appName];
	}
	
	NSString *tempDirectoryPath = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:tempDirectoryNameCString length:strlen(result)];
	free(tempDirectoryNameCString);
	
	tempFilePath = [tempDirectoryPath stringByAppendingPathComponent:[aURL lastPathComponent]];
	return tempFilePath;
}

- (int)unzip:(NSString *)aZipFilePath error:(NSError **)err
{
	NSError *aErr = nil;
	NSString *parentDir = [aZipFilePath stringByDeletingLastPathComponent];
	[self unzip:aZipFilePath targetPath:parentDir error:&aErr];
	if (err != NULL) *err = aErr;
    return 0;
}

- (int)unzip:(NSString *)aZipFilePath targetPath:(NSString *)aTargetPath error:(NSError **)err
{	
	NSError *aErr = nil;
	NSString *binFile = @"/usr/bin/ditto";
	NSArray *binArgs = [NSArray arrayWithObjects:@"-x", @"-k", aZipFilePath, aTargetPath, nil];
	NSString *result;
	result = [self runTask:binFile binArgs:binArgs error:&aErr];
	if (err != NULL) *err = aErr;
    return 0;
}

-(NSString *)runTask:(NSString *)aBinPath binArgs:(NSArray *)aArgs error:(NSError **)err
{
	NSError *error = nil;
	NSString *result;
	result = [self runTask:aBinPath binArgs:aArgs environment:nil error:&error];
	if (error)
	{
		if (err != NULL) *err = error;
	}
	
    return [result trim];
}

-(NSString *)runTask:(NSString *)aBinPath binArgs:(NSArray *)aArgs environment:(NSDictionary *)aEnv error:(NSError **)err
{
    [self setTaskTimedOut:NO];
    NSString *resultString;
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:aBinPath];
    [task setArguments:aArgs];
    
    if ([aBinPath isEqual:@"/usr/sbin/installer"]) {
        NSDictionary *defaultEnvironment = [[NSProcessInfo processInfo] environment];
        NSMutableDictionary *environment = [[NSMutableDictionary alloc] initWithDictionary:defaultEnvironment];
        [environment setObject:@"YES" forKey:@"NSUnbufferedIO"];
        [environment setObject:@"1" forKey:@"COMMAND_LINE_INSTALL"];
        [task setEnvironment:environment];
    } else {
        if (aEnv) {
            [task setEnvironment:aEnv];
        }
    }
    
    NSPipe *readPipe = [NSPipe pipe];
    NSFileHandle *readHandle = [readPipe fileHandleForReading];
    
    NSPipe *writePipe = [NSPipe pipe];
    NSFileHandle *writeHandle = [writePipe fileHandleForWriting];
    
    [task setStandardInput: writePipe];
    [task setStandardOutput: readPipe];
    [task setStandardError: readPipe];
    
    // Launch The NSTask
    @try {
        [task launch];
        // If timeout is set start it ...
        if (taskTimeoutValue != 0) {
            [NSThread detachNewThreadSelector:@selector(taskTimeoutThread) toTarget:self withObject:nil];
        }
    }
    @catch (NSException *e)
    {
        logit(lcl_vError,@"Install returned error. %@\n%@",[e reason],[e userInfo]);
        if(taskTimeoutTimer) {
            [taskTimeoutTimer invalidate];
        }
        if (err != NULL) *err = [NSError errorWithDomain:@"RunTask" code:1001 userInfo:[e userInfo]];
        return @"ERROR";
    }

    [writeHandle writeData:[NSData dataWithContentsOfFile:@"/private/tmp/.MPRead"]];
    [writeHandle closeFile];
    
    NSMutableData *data = [[NSMutableData alloc] init];
    NSData *readData;
    
    // Read til we have no more data or task has timed out
    while (taskTimedOut == NO && (readData = [readHandle availableData]) && [readData length])
    {
        NSString *l_string = [[NSString alloc] initWithData:readData encoding:NSUTF8StringEncoding];
        logit(lcl_vDebug,@"%@",[l_string stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:[NSLocale currentLocale]]);
        [data appendData: readData];
        l_string = nil;
    }
    
    // Output String
    NSString *outputString = [[NSString alloc] initWithData:data encoding: NSUTF8StringEncoding];
    resultString = [outputString stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:[NSLocale currentLocale]];
    
    // If tasked timedout kill the task
    if (taskTimedOut == YES) {
        // Kill Current Task
        kill([task processIdentifier], SIGKILL);
        NSDictionary *errUserInfo = @{NSLocalizedDescriptionKey : @"Task timed out, and was killed."};
        if (err != NULL) *err = [NSError errorWithDomain:@"runTask" code:TaskErrorTimedOut userInfo:errUserInfo];
        return @"ERROR";
    }
    
    // make sure the task is no longer running
    while ([task isRunning] && taskTimedOut == NO)
    {
        if ([task isRunning]) {
            logit(lcl_vInfo,@"Task is running");
        } else {
            logit(lcl_vInfo,@"a) Task is running");
        }
        [NSThread sleepForTimeInterval:1.0];
    }
    
    // If tasked timedout kill the task
    if (taskTimedOut == YES) {
        // Kill Current Task
        kill([task processIdentifier], SIGKILL);
        NSDictionary *errUserInfo = @{NSLocalizedDescriptionKey : @"Task timed out, and was killed."};
        if (err != NULL) *err = [NSError errorWithDomain:@"runTask" code:TaskErrorTimedOut userInfo:errUserInfo];
        return @"ERROR";
    }
    
    
    if ([task terminationStatus] != 0) {
        logit(lcl_vError,@"Error, unable to run task.");
        if (err != NULL) *err = [NSError errorWithDomain:@"RunTask" code:[task terminationStatus] userInfo:nil];
    } else {
        logit(lcl_vInfo,@"Task Terminated with 0.");
    }
    
    return resultString;
}

- (int)installPkg:(NSString *)pkgPath error:(NSError **)err
{
	NSError *aErr = nil;
	[self installPkg:pkgPath target:@"/" error:&aErr];
	if (err != NULL) *err = aErr;
    return 0;
}

- (int)installPkg:(NSString *)pkgPath target:(NSString *)aTarget error:(NSError **)err
{
	NSError *aErr = nil;
	NSString *result;
	result = [self installPkgWithResult:pkgPath target:aTarget error:&aErr];
	if (err != NULL) *err = aErr;
    return 0;
}

-(NSString *)installPkgWithResult:(NSString *)pkgPath target:(NSString *)aTarget error:(NSError **)err
{
	NSString *result;
#ifdef DEBUG	
	result = NULL;
#else	
	NSError *aErr = nil;
	NSArray *binArgs = [NSArray arrayWithObjects:@"-verboseR", @"-allowUntrusted", @"-pkg", pkgPath, @"-target", aTarget, nil];
	NSDictionary *env = [NSDictionary dictionaryWithObject:@"1" forKey:@"COMMAND_LINE_INSTALL"];
	result = [self runTask:INSTALLER_BIN_PATH binArgs:binArgs environment:env error:&aErr];
	if (err != NULL) *err = aErr;
#endif
	
	return result;
}

- (void)taskTimeoutThread
{
    @autoreleasepool
    {
        logit(lcl_vDebug,@"Timeout is set to %f",taskTimeoutValue);
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:taskTimeoutValue
                                                          target:self
                                                        selector:@selector(taskTimeout:)
                                                        userInfo:nil
                                                         repeats:NO];
        [self setTaskTimeoutTimer:timer];
        while (taskTimedOut == NO && [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
        
    }
    
}

- (void)taskTimeout:(NSNotification *)aNotification
{
    logit(lcl_vInfo,@"Task timedout, killing task.");
    [self.taskTimeoutTimer invalidate];
    [self setTaskTimedOut:YES];
}

#pragma mark Migration methods

- (BOOL)scanForMigrationConfig
{
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:_migrationPlist]) {
        [self setUseMigrationConfig:YES];
        return YES;
    }
    
    return NO;
}

- (MPNetServer *)migrationServerConfig
{
    NSDictionary *_altConf = [NSDictionary dictionaryWithContentsOfFile:_migrationPlist];
    
    if (_altConf) {
        if ([_altConf objectForKey:@"fingerprint"]) {
            if ([[_altConf objectForKey:@"fingerprint"] length] >= 40) {
                [self setVerifyFingerprint:YES];
                [self setFingerprint:[_altConf objectForKey:@"fingerprint"]];
            }
        }

        MPNetServer *conf = [[MPNetServer alloc] init];
        [conf setHost:[_altConf objectForKey:@"MPServerAddress"]];
        [conf setPort:[[_altConf objectForKey:@"MPServerPort"] integerValue]];
        [conf setAllowSelfSigned:YES];
        return conf;
    }
    logit(lcl_vError,@"Migration Plist was nil.");
    return nil;
}

- (BOOL)validateRemoteFingerprint:(NSString *)url
{
    NSURL *_url = [NSURL URLWithString:url];
    MPRemoteFingerprint *rf = [[MPRemoteFingerprint alloc] init];
    return [rf isValidRemoteFingerPrint:_url fingerprint:[self fingerprint]];
}

#pragma mark REST Request
/*
 These methods are for migration
*/

- (NSData *)getRequestWithURIforREST:(NSString *)aURI error:(NSError **)err
{
    MPNetServer *server = [self migrationServerConfig];
    if (!server) {
        return nil;
    }
    
    if (self.verifyFingerprint) {
        NSString *url = [NSString stringWithFormat:@"https://%@:%d",server.host,(int)server.port];
        BOOL isValidCert = [self validateRemoteFingerprint:url];
        if (!isValidCert) {
            qlerror(@"Remote Certificate finger print verify failed.");
            return nil;
        }
    }

    MPNetConfig *mpNetConfig = [[MPNetConfig alloc] initWithServer:server];
    
    NSError *error = nil;
    NSURLResponse *response;
    
    MPNetRequest *req;
    NSURLRequest *urlReq;
    NSData *res = nil;
    NSArray *servers = [mpNetConfig servers];
    for (MPNetServer *srv in servers)
    {
        qlinfo(@"Trying Server %@",srv.host);
        req = [[MPNetRequest alloc] initWithMPServer:srv];
        error = nil;
        urlReq =  [req buildJSONGETRequest:aURI error:&error];
        if (error) {
            if (err != NULL) {
                *err = error;
            }
            qlerror(@"[%@][%d](%@ %d): %@",srv.host,(int)srv.port,error.domain,(int)error.code,error.localizedDescription);
            continue;
        }
        error = nil;
        if (urlReq)
        {
            res = nil;
            res = [req sendSynchronousRequest:urlReq returningResponse:&response error:&error];
            if (error) {
                if (err != NULL) {
                    *err = error;
                }
                qlerror(@"[%@][%d](%@ %d): %@",srv.host,(int)srv.port,error.domain,(int)error.code,error.localizedDescription);
                continue;
            }
            // Make any previouse error pointers nil, now that we have a valid host/connection
            if (err != NULL) {
                *err = nil;
            }
            break;
        } else {
            NSDictionary *userInfo = [NSDictionary dictionaryWithObject:@"NSURLRequest was nil." forKey:NSLocalizedDescriptionKey];
            error = [NSError errorWithDomain:NSOSStatusErrorDomain code:-1001 userInfo:userInfo];
            qlerror(@"%@",error.localizedDescription);
            if (err != NULL) {
                *err = error;
            }
            continue;
        }
    }
    
    return res;
}

- (id)restGetRequestforURI:(NSString *)aURI resultType:(NSString *)resType error:(NSError **)err
{
    NSError *wsErr = nil;
    NSData *reqData;
    id result;
    
    @try
    {
        reqData = [self getRequestWithURIforREST:aURI error:&wsErr];
        if (wsErr) {
            if (err != NULL) *err = wsErr;
            logit(lcl_vError,@"%@",wsErr.localizedDescription);
            return nil;
        } else {
            // Parse JSON result, if error code is not 0
            wsErr = nil;
            result = [self returnRequestWithType:reqData resultType:resType error:&wsErr];
            if (wsErr) {
                if (err != NULL) *err = wsErr;
                logit(lcl_vError,@"%@",wsErr.localizedDescription);
                return nil;
            }
            logit(lcl_vDebug,@"%@",result);
            return result;
        }
        
    }
    @catch (NSException * e) {
        logit(lcl_vError,@"[NSException]: %@",e);
    }
    // Should not get here
    return nil;
}

// Parses Request Result using know reponse result type (json, string)
- (id)returnRequestWithType:(NSData *)requestData resultType:(NSString *)resultType error:(NSError **)err
{
    MPJsonResult *jres = [[MPJsonResult alloc] init];
    [jres setJsonData:requestData];
    NSError *error = nil;
    id result;
    
    if ([resultType isEqualToString:@"json"]) {
        result = [jres returnJsonResult:&error];
        qldebug(@"JSON Result: %@",result);
    } else {
        result = [jres returnResult:&error];
    }
    
    if (error) {
        if (err != NULL) {
            *err = error;
        } else {
            qlerror(@"%@",error.localizedDescription);
        }
        return nil;
    }
    
    return result;
}

- (NSDictionary *)getAgentUpdates:(NSString *)curAppVersion build:(NSString *)curBuildVersion error:(NSError **)err
{
    NSError *error = nil;
    NSDictionary *result = nil;
    NSString *aURI = [NSString stringWithFormat:@"/api/v1/agent/update/%@/%@/%@",[MPSystemInfo clientUUID], curAppVersion, curBuildVersion];
    result = [self restGetRequestforURI:aURI resultType:@"json" error:&error];
    if (err != NULL) *err = error;
    return result;
}

@end
