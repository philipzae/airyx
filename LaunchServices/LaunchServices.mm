/*
 * Airyx LaunchServices
 *
 * Copyright (C) 2021 Zoe Knox <zoe@pixin.net>
 * 
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

#import <Foundation/Foundation.h>
#import <Foundation/NSRaiseException.h>
#import <CoreFoundation/CoreFoundation.h>
#import <LaunchServices/LaunchServices.h>
#import "LSAppRecord.h"

#include <sqlite3.h>

//const char *LS_DATABASE = "/var/db/launchservices.db";
const char *LS_DATABASE = "./launchservices.db";

// #include <KIO/ApplicationLauncherJob>
// #include <KIO/OpenUrlJob>
// #include <KService>


// FIXME: these should talk to a privileged service (maybe over DBus) but for now we'll
// just manipulate some files. The service is /System/Library/CoreServices/launchservicesd
// on macOS.
// See https://developer.gnome.org/DBusApplicationLaunching/ and 
// https://techbase.kde.org/Development/Tutorials/D-Bus/Autostart_Services

// FIXME: add search fn and table uti: type, app URL, handler rank
// FIXME: add search fn and table extension: ext, uti

// FIXME: which error code to return for each case is just a guess

// FIXME: stuff to track per application:
// - DBus activatable boolean

//------------------------------------------------------------------------
//    INTERNAL FUNCTIONS - DON'T USE. SEE BELOW FOR PUBLIC API
//------------------------------------------------------------------------

static BOOL _LSFindRecordInDatabase(const NSURL *appURL, LSAppRecord **appRecord)
{
    sqlite3 *pDB = 0;
    if(sqlite3_open(LS_DATABASE, &pDB) != SQLITE_OK) {
        sqlite3_close(pDB);
        return false; // FIXME: log error somewhere
    }
    
    const char *query = "SELECT * FROM applications WHERE url=? OR basename=?";
    const int length = strlen(query);
    sqlite3_stmt *stmt;
    const char *tail;

    if(sqlite3_prepare_v2(pDB, query, length, &stmt, &tail) != SQLITE_OK) {
        sqlite3_close(pDB);
        return false;
    }

    if(sqlite3_bind_text(stmt, 1, [[appURL absoluteString] UTF8String], [[appURL absoluteString] length], SQLITE_STATIC) != SQLITE_OK
        || sqlite3_bind_text(stmt, 2, [[appURL lastPathComponent] UTF8String], [[appURL lastPathComponent] length], SQLITE_STATIC) != SQLITE_OK)
    {
        sqlite3_finalize(stmt);
        sqlite3_close(pDB);
        return false;
    }

    int rc = sqlite3_step(stmt);
    if(rc == SQLITE_ROW) {
        NSData *blob = [[NSData alloc] 
            initWithBytes:sqlite3_column_blob(stmt, 3)
            length:sqlite3_column_bytes(stmt, 3)];
        *appRecord = [NSKeyedUnarchiver unarchiveObjectWithData:blob];
    }

    sqlite3_finalize(stmt);
    sqlite3_close(pDB);
    return (rc == SQLITE_ROW) ? true : false;
}

static BOOL _LSFileExtensionToUTI(NSString *ext, NSString **outUTI)
{
    sqlite3 *pDB = 0;
    if(sqlite3_open(LS_DATABASE, &pDB) != SQLITE_OK) {
        sqlite3_close(pDB);
        return false; // FIXME: log error somewhere
    }
    
    const char *query = "SELECT uti FROM extensions WHERE ext=?";
    const int length = strlen(query);
    sqlite3_stmt *stmt;
    const char *tail;

    if(sqlite3_prepare_v2(pDB, query, length, &stmt, &tail) != SQLITE_OK) {
        sqlite3_close(pDB);
        return false;
    }

    if(sqlite3_bind_text(stmt, 1, [ext UTF8String], [ext length], SQLITE_STATIC) != SQLITE_OK) {
        sqlite3_finalize(stmt);
        sqlite3_close(pDB);
        return false;
    }

    int rc = sqlite3_step(stmt);
    if(rc == SQLITE_ROW)
        *outUTI = [NSString stringWithCString:(const char *)sqlite3_column_text(stmt, 1)];

    sqlite3_finalize(stmt);
    sqlite3_close(pDB);
    return (rc == SQLITE_ROW) ? true : false;
}

static OSStatus _LSFindAppsForUTI(NSString *uti, NSMutableArray **outAppURLs)
{
    sqlite3 *pDB = 0;
    if(sqlite3_open(LS_DATABASE, &pDB) != SQLITE_OK) {
        sqlite3_close(pDB);
        return kLSServerCommunicationErr; // FIXME: log error somewhere
    }
    
    const char *query = "SELECT application,rank FROM typemap WHERE uti=? ORDER BY rank ASC";
    const int length = strlen(query);
    sqlite3_stmt *stmt;
    const char *tail;

    if(sqlite3_prepare_v2(pDB, query, length, &stmt, &tail) != SQLITE_OK) {
        sqlite3_close(pDB);
        return kLSServerCommunicationErr;
    }

    if(sqlite3_bind_text(stmt, 1, [uti UTF8String], [uti length], SQLITE_STATIC) != SQLITE_OK) {
        sqlite3_finalize(stmt);
        sqlite3_close(pDB);
        return kLSServerCommunicationErr;
    }

    int rc = sqlite3_step(stmt);
    if(rc != SQLITE_ROW)
        return kLSApplicationNotFoundErr;

    for(; rc == SQLITE_ROW; rc = sqlite3_step(stmt)) {
        NSString *url = [NSString stringWithCString:(const char *)sqlite3_column_text(stmt, 1)];
        [*outAppURLs addObject:url];
    }

    sqlite3_finalize(stmt);
    sqlite3_close(pDB);
    return 0;
}

// Returns a sorted list of apps that can accept "extension"
static OSStatus _LSFindAppsForExtension(NSString *extension, NSMutableArray **outAppURLs)
{
    NSString *uti;
    if(_LSFileExtensionToUTI(extension, &uti) == false)
        return kLSDataUnavailableErr;
    return _LSFindAppsForUTI(uti, outAppURLs);
}

static BOOL _LSAddRecordToDatabase(const LSAppRecord *appRecord, BOOL isUpdate) {
    sqlite3 *pDB = 0;
    if(sqlite3_open(LS_DATABASE, &pDB) != SQLITE_OK) {
        sqlite3_close(pDB);
        return false; // FIXME: log error somewhere
    }
    
    const char *query;
    if(isUpdate)
        query = "UPDATE applications SET basename=?2, version=?3, apprecord=?4 WHERE url=?1";
    else
        query = "INSERT INTO applications (url,basename,version,apprecord) VALUES (?1,?2,?3,?4)";
    const int length = strlen(query);
    sqlite3_stmt *stmt;
    const char *tail;

    if(sqlite3_prepare_v2(pDB, query, length, &stmt, &tail) != SQLITE_OK) {
        sqlite3_close(pDB);
        return false;
    }

    NSData *blob = [NSKeyedArchiver archivedDataWithRootObject:appRecord];
    if(sqlite3_bind_text(stmt, 1, [[[appRecord URL] absoluteString] UTF8String], [[[appRecord URL] absoluteString] length], SQLITE_STATIC) != SQLITE_OK
        || sqlite3_bind_text(stmt, 2, [[[appRecord URL] lastPathComponent] UTF8String], [[[appRecord URL] lastPathComponent] length], SQLITE_STATIC) != SQLITE_OK
        || sqlite3_bind_int(stmt, 3, [appRecord version]) != SQLITE_OK
        || sqlite3_bind_blob(stmt, 4, [blob bytes], [blob length], SQLITE_STATIC) != SQLITE_OK)
    {
        sqlite3_finalize(stmt);
        sqlite3_close(pDB);
        return false;
    }

    if(sqlite3_step(stmt) != SQLITE_DONE)
        return false;

    sqlite3_finalize(stmt);
    sqlite3_close(pDB);
    return true;
}

static OSStatus _LSOpenAllWithSpecifiedApp(const LSLaunchURLSpec *inLaunchSpec, CFURLRef _Nullable *outLaunchedURL)
{
    const NSURL *appURL = (NSURL *)inLaunchSpec->appURL;
    if([appURL isFileURL] == NO)
        return kLSDataErr;

    // Launch app and pass all itemURLs to it
    // FIXME: use GURL or odoc events instead of passing on cmd line
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *appPath = [appURL path];
    BOOL isDir;
    BOOL exists = [fm fileExistsAtPath:appPath isDirectory:&isDir];

    if(exists == NO)
        return kLSNoExecutableErr;

    if(isDir == YES) {
        NSBundle *app = [NSBundle bundleWithPath:appPath];
        if([fm isExecutableFileAtPath:[app executablePath]] == NO)
            return kLSNoExecutableErr;

        if(outLaunchedURL != NULL)
            *outLaunchedURL = (CFURLRef)[NSURL fileURLWithPath:[app executablePath]];
        
        NSMutableArray *args = [[app infoDictionary] objectForKey:@"ProgramArguments"];
        [args addObjectsFromArray:(NSArray *)inLaunchSpec->itemURLs];
        [NSTask launchedTaskWithLaunchPath:[app executablePath] arguments:args];
    } else {
        // it's not a bundle so just try to exec the file
        if([fm isExecutableFileAtPath:appPath] == NO)
            return kLSNoExecutableErr;

        if(outLaunchedURL != NULL)
            *outLaunchedURL = (CFURLRef)[NSURL fileURLWithPath:appPath];

        // Check if we have any stored arguments in the database
        LSAppRecord *appRecord;
        NSMutableArray *args = [NSMutableArray alloc];
        if(_LSFindRecordInDatabase(appURL, &appRecord) == YES) {
            [args addObjectsFromArray:[appRecord arguments]];
        }

        BOOL found = NO;
        for(int i=0; i<[args count]; ++i) {
            if([[args objectAtIndex:i] caseInsensitiveCompare:@"%U"] == NSOrderedSame) {
                [args replaceObjectAtIndex:i withObject:[[(NSArray *)inLaunchSpec->itemURLs firstObject] absoluteString]];
                found = YES;
            }
            if([[args objectAtIndex:i] caseInsensitiveCompare:@"%F"] == NSOrderedSame) {
                [args replaceObjectAtIndex:i withObject:[[(NSArray *)inLaunchSpec->itemURLs firstObject] path]];
                found = YES;
            }
        }

        if(found == NO)
            [args addObject:[[(NSArray *)inLaunchSpec->itemURLs firstObject] path]];
        [args retain];
        [NSTask launchedTaskWithLaunchPath:appPath arguments:args];
        [args release];
    }
    return 0;
}

static BOOL _acceptsThing(NSArray *things, NSString *aThing)
{
    NSEnumerator *thingEnumerator = [things objectEnumerator];
    NSString *currentThing;
    while(currentThing = [thingEnumerator nextObject]) {
        if([currentThing isEqualToString:@"*"] || [currentThing isEqualToString:aThing]) {
            return YES;
        }
    }
    return NO;
}

static BOOL _acceptsRole(NSString *role, LSRolesMask rolesMask)
{
    if([role isEqualToString:@"None"]) return NO;
    if(rolesMask == kLSRolesAll) return YES;
    if([role isEqualToString:@"Shell"] && (rolesMask & kLSRolesShell)) return YES;
    if([role isEqualToString:@"Viewer"] && (rolesMask & kLSRolesViewer)) return YES;
    if([role isEqualToString:@"Editor"] && (rolesMask & kLSRolesEditor)) return YES;
    return NO;
}

//------------------------------------------------------------------------
//    PUBLIC API
//------------------------------------------------------------------------

OSStatus LSOpenCFURLRef(CFURLRef inURL, CFURLRef _Nullable *outLaunchedURL)
{
    LSLaunchURLSpec spec;
    spec.appURL = inURL;
    spec.asyncRefCon = 0;
    spec.itemURLs = CFArrayCreate(NULL, (const void **)&inURL, 1, NULL);
    spec.launchFlags = kLSLaunchDefaults;
    OSStatus rc = LSOpenFromURLSpec(&spec, outLaunchedURL);
    CFRelease(spec.itemURLs);
    return rc;
}


OSStatus LSOpenFromURLSpec(const LSLaunchURLSpec *inLaunchSpec, CFURLRef _Nullable *outLaunchedURL)
{
    if(inLaunchSpec->appURL) {
        // We are launching this specific application which must be a file URL
        return _LSOpenAllWithSpecifiedApp(inLaunchSpec, outLaunchedURL);
    }

    // We are opening one or more files or URLs with their preferred apps
    // If any of the items refer to application bundles, they will be launched
    // NOTE: Plain executable files are NOT considered "applications" here
    // because file permissions are not reliable. e.g. Samba shares often have
    // execute permission on non-executable files.

    NSEnumerator *items = [(id)(inLaunchSpec->itemURLs) objectEnumerator];
    NSURL *item;

    while(item = [items nextObject]) {
        NSLog(@"item = %@", item);

        if(/* item is app bundle */ 0) {
            // launch it
        } else {
            NSMutableArray *appCandidates;
            if(_LSFindAppsForExtension([item pathExtension], &appCandidates) == 0) {
                LSLaunchURLSpec spec;
                spec.appURL = (CFURLRef)[appCandidates firstObject];
                spec.itemURLs = (CFArrayRef)[NSArray arrayWithObject:item];
                spec.launchFlags = kLSLaunchDefaults;
                _LSOpenAllWithSpecifiedApp(&spec, NULL);
            }
        }    
    }

    return 0;
}

OSStatus LSRegisterURL(CFURLRef inURL, Boolean inUpdate)
{
    // Per Apple, inURL must be a file URL that refers to an app bundle
    // or executable. This version will also accept a .desktop file as
    // a special case.

    NSURL *appURL = (NSURL *)inURL;
    if([appURL isFileURL] == NO)
        return kLSDataErr;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *appPath = [appURL path];
    BOOL isDir;
    BOOL exists = [fm fileExistsAtPath:appPath isDirectory:&isDir];
    BOOL isDesktopFile = [appPath hasSuffix:@".desktop"];

    if(exists == NO)
        return kLSNoExecutableErr;

    if(isDir == YES) {
        NSBundle *app = [NSBundle bundleWithPath:appPath];
        if([fm isExecutableFileAtPath:[app executablePath]] == NO)
            return kLSNoExecutableErr;
    } else {
        if( isDesktopFile == NO && [fm isExecutableFileAtPath:appPath] == NO)
            return kLSNoExecutableErr;
    }

    NSDictionary *attributes = [fm fileAttributesAtPath:appPath traverseLink:NO];

    // Does this app exist in the database already?
    LSAppRecord *appRecord = [LSAppRecord new];
    BOOL inDatabase = _LSFindRecordInDatabase(appURL, &appRecord);

    if(inDatabase == YES && inUpdate == NO && [appRecord modificationDate] == [attributes fileModificationDate])
        return 0; // Date hasn't changed and "force update" not specified

    // Either record did not exist, file has been modified, or an update is forced
    [appRecord initWithURL:appURL];
    BOOL rc = _LSAddRecordToDatabase(appRecord, inDatabase);
    return (rc == true) ? 0 : kLSServerCommunicationErr;
}

OSStatus LSCanURLAcceptURL(CFURLRef inItemURL, CFURLRef inTargetURL, LSRolesMask inRoleMask, LSAcceptanceFlags inFlags, Boolean *outAcceptsItem)
{
    *outAcceptsItem = NO;

    NSURL *appURL = (NSURL *)inTargetURL;
    if([appURL isFileURL] == NO)
        return kLSDataErr;

    LSAppRecord *appRecord = [LSAppRecord new];
    if(_LSFindRecordInDatabase(appURL, &appRecord) == NO)
        return kLSApplicationNotFoundErr;

    if([[(NSURL *)inItemURL scheme] isEqualToString:@"file"]) {
        NSString *ext = [(NSURL *)inItemURL pathExtension];
        NSString *uti;
        _LSFileExtensionToUTI(ext, &uti);

        NSEnumerator *docTypes = [[appRecord documentTypes] objectEnumerator];
        NSDictionary *docType;

        while(docType = [docTypes nextObject]) {
            NSArray *things = [docType objectForKey:kLSItemContentTypesKey];
            if([things count]) {
                if(_acceptsThing(things, uti) && _acceptsRole([docType objectForKey:kCFBundleTypeRoleKey], inRoleMask)) {
                    *outAcceptsItem = YES;
                    break;
                }
            } else {
                things = [docType objectForKey:kCFBundleTypeExtensionsKey];
                if(_acceptsThing(things, ext) && _acceptsRole([docType objectForKey:kCFBundleTypeRoleKey], inRoleMask)) {
                    *outAcceptsItem = YES;
                    break;
                }
            }
        }
    } else {
        NSString *itemScheme = [(NSURL *)inItemURL scheme];
        NSEnumerator *appSchemes = [[appRecord URLSchemes] objectEnumerator];
        NSDictionary *appScheme;

        while(appScheme = [appSchemes nextObject]) {
            if(_acceptsThing([appScheme objectForKey:kCFBundleURLSchemesKey], itemScheme) && _acceptsRole([appScheme objectForKey:kCFBundleTypeRoleKey], inRoleMask)) {
                *outAcceptsItem = YES;
                break;
            }
        }
    }

    return 0;
}