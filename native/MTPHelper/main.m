// WinFile MTP transport. JSON-lines stdout is private; library diagnostics go to stderr.
// Each request owns a session. The Swift client serializes requests and bounds lifetime.
#import <Foundation/Foundation.h>
#include <libmtp.h>
#include <libusb.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <signal.h>

static int resultFD;
static volatile sig_atomic_t cancelled;
static void stopTransfer(int signal) {
    (void)signal;
    cancelled = 1;
}
static void emit(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    NSMutableData *line = [data mutableCopy];
    [line appendBytes:"\n" length:1];
    const char *p = line.bytes;
    size_t n = line.length;
    while (n) {
        ssize_t sent = write(resultFD, p, n);
        if (sent < 0 && errno == EINTR)
            continue;
        if (sent <= 0)
            break;
        p += sent;
        n -= sent;
    }
}
static void fail(NSString *code) {
    @throw [NSException exceptionWithName:code reason:code userInfo:nil];
}
static void require(BOOL ok, NSString *code) {
    if (!ok)
        fail(code);
}
static NSString *str(const char *s) {
    return s ? [NSString stringWithUTF8String:s] ?: @"" : @"";
}
static NSString *owned(char *s) {
    NSString *text = str(s);
    free(s);
    return text;
}
static BOOL validName(NSString *s) {
    return [s isKindOfClass:NSString.class] && s.length && ![s isEqual:@"."] && ![s isEqual:@".."] &&
           ![s containsString:@"/"] && ![s containsString:[NSString stringWithFormat:@"%C", (unichar)0]];
}
static NSString *transport(uint16_t vid, uint16_t pid, uint32_t bus, uint8_t number) {
    return [NSString stringWithFormat:@"%04x-%04x-%u-%u", vid, pid, bus, number];
}
static NSString *rawTransport(LIBMTP_raw_device_t raw) {
    return transport(raw.device_entry.vendor_id, raw.device_entry.product_id, raw.bus_location, raw.devnum);
}
static uint32_t parentHandle(NSDictionary *entry) {
    uint32_t value = [entry[@"objectID"] unsignedIntValue];
    return value ?: LIBMTP_FILES_AND_FOLDERS_ROOT;
}
static NSString *storagePath(uint32_t storage) {
    return [NSString stringWithFormat:@"/storage-%u", storage];
}
static int progress(uint64_t sent, uint64_t total, const void *context) {
    (void)context;
    if (cancelled)
        return 1;
    // Avoid thousands of pipe writes per second; always send completion.
    static double last = -1;
    double value = total ? (double)sent / total : 0;
    if (last < 0 || value >= 1 || value - last >= 0.005 || value < last) {
        emit(@{@"progress" : @(value)});
        last = value;
    }
    return 0;
}
static void freeFiles(LIBMTP_file_t *files) {
    while (files) {
        LIBMTP_file_t *next = files->next;
        LIBMTP_destroy_file_t(files);
        files = next;
    }
}
static LIBMTP_file_t *children(LIBMTP_mtpdevice_t *device, uint32_t storage, uint32_t parent) {
    if (cancelled)
        fail(@"cancelled");
    LIBMTP_Clear_Errorstack(device);
    LIBMTP_file_t *files = LIBMTP_Get_Files_And_Folders(device, storage, parent ?: LIBMTP_FILES_AND_FOLDERS_ROOT);
    require(!LIBMTP_Get_Errorstack(device), @"read");
    return files;
}
static NSDictionary *entry(LIBMTP_file_t *f, NSString *parent) {
    NSString *name = str(f->filename);
    require(validName(name), @"invalidName");
    return @{
        @"name" : name,
        @"path" : [parent stringByAppendingPathComponent:name],
        @"objectID" : @(f->item_id),
        @"storageID" : @(f->storage_id),
        @"isDirectory" : (f->filetype == LIBMTP_FILETYPE_FOLDER ? @YES : @NO),
        @"size" : @(f->filesize),
        @"modified" : @((int64_t)f->modificationdate)
    };
}
static NSArray *storages(LIBMTP_mtpdevice_t *device) {
    require(LIBMTP_Get_Storage(device, LIBMTP_STORAGE_SORTBY_NOTSORTED) == 0, @"locked");
    NSMutableArray *result = [NSMutableArray array];
    for (LIBMTP_devicestorage_t *s = device->storage; s; s = s->next) {
        [result addObject:@{
            @"id" : @(s->id),
            @"path" : storagePath(s->id),
            @"label" : str(s->StorageDescription).length ? str(s->StorageDescription) : @"Storage",
            @"isRemovable" : (s->StorageType == 4 || s->StorageType == 2 ? @YES : @NO),
            @"capacity" : @(s->MaxCapacity),
            @"free" : @(s->FreeSpaceInBytes)
        }];
    }
    return result;
}
// Path names are presentation only; every operation resolves them to current storage/object IDs.
// Old saved ADB addresses are aliases for the first MTP shared storage, never shell paths.
static NSString *normalize(NSString *path, NSArray *stores) {
    require([path isKindOfClass:NSString.class] && [path hasPrefix:@"/"] &&
                ![path containsString:[NSString stringWithFormat:@"%C", (unichar)0]],
            @"invalidPath");
    NSMutableArray *components = [NSMutableArray array];
    for (NSString *part in [path componentsSeparatedByString:@"/"]) {
        require(![part isEqual:@".."] && ![part isEqual:@"."], @"invalidPath");
        if (part.length)
            [components addObject:part];
    }
    // NSURL parent navigation appends a slash. NSString.pathComponents treats that
    // slash as another component, which would incorrectly resolve a child named "/".
    path = [@"/" stringByAppendingString:[components componentsJoinedByString:@"/"]];
    for (NSString *old in @[ @"/storage/emulated/0", @"/storage/self/primary", @"/sdcard" ]) {
        if ([path isEqual:old] || [path hasPrefix:[old stringByAppendingString:@"/"]]) {
            require(stores.count > 0, @"locked");
            return [stores[0][@"path"] stringByAppendingString:[path substringFromIndex:old.length]];
        }
    }
    return path;
}
static NSDictionary *resolve(LIBMTP_mtpdevice_t *device, NSString *path, NSArray *stores) {
    path = normalize(path, stores);
    NSArray *parts = [path pathComponents];
    require(parts.count >= 2, @"invalidPath");
    NSDictionary *storage = nil;
    for (NSDictionary *s in stores)
        if ([s[@"path"] isEqual:[@"/" stringByAppendingString:parts[1]]]) {
            storage = s;
            break;
        }
    require(storage != nil, @"notFound");
    uint32_t sid = [storage[@"id"] unsignedIntValue], parent = 0;
    NSDictionary *found = @{
        @"name" : storage[@"label"],
        @"path" : storage[@"path"],
        @"storageID" : @(sid),
        @"objectID" : @0,
        @"isDirectory" : @YES,
        @"size" : @0,
        @"modified" : @0
    };
    NSString *current = storage[@"path"];
    for (NSUInteger i = 2; i < parts.count; i++) {
        require([found[@"isDirectory"] boolValue], @"notFolder");
        LIBMTP_file_t *files = children(device, sid, parent);
        NSDictionary *match = nil;
        @try {
            for (LIBMTP_file_t *f = files; f; f = f->next)
                if ([str(f->filename) isEqual:parts[i]]) {
                    require(match == nil, @"ambiguous");
                    match = entry(f, current);
                }
        } @finally {
            freeFiles(files);
        }
        require(match != nil, @"notFound");
        found = match;
        parent = [found[@"objectID"] unsignedIntValue];
        current = found[@"path"];
    }
    return found;
}
static NSDictionary *findChild(LIBMTP_mtpdevice_t *device, NSDictionary *parent, NSString *name) {
    LIBMTP_file_t *files =
        children(device, [parent[@"storageID"] unsignedIntValue], [parent[@"objectID"] unsignedIntValue]);
    NSDictionary *found = nil;
    @try {
        for (LIBMTP_file_t *f = files; f; f = f->next)
            if ([str(f->filename) isEqual:name]) {
                require(!found, @"ambiguous");
                found = entry(f, parent[@"path"]);
            }
    } @finally {
        freeFiles(files);
    }
    return found;
}
static NSDictionary *makeFolder(LIBMTP_mtpdevice_t *device, NSDictionary *parent, NSString *name) {
    require(validName(name), @"invalidName");
    require([parent[@"isDirectory"] boolValue], @"notFolder");
    require(!findChild(device, parent, name), @"exists");
    uint32_t id = LIBMTP_Create_Folder(device, (char *)name.UTF8String, parentHandle(parent),
                                       [parent[@"storageID"] unsignedIntValue]);
    require(id != 0, @"write");
    return @{
        @"objectID" : @(id),
        @"storageID" : parent[@"storageID"],
        @"path" : [parent[@"path"] stringByAppendingPathComponent:name],
        @"name" : name,
        @"isDirectory" : @YES,
        @"size" : @0,
        @"modified" : @0
    };
}
static void download(LIBMTP_mtpdevice_t *device, NSDictionary *source, NSString *local, NSUInteger depth) {
    require(depth < 128, @"tooDeep");
    if (cancelled)
        fail(@"cancelled");
    if ([source[@"isDirectory"] boolValue]) {
        require(mkdir(local.fileSystemRepresentation, 0700) == 0, @"localWrite");
        LIBMTP_file_t *files =
            children(device, [source[@"storageID"] unsignedIntValue], [source[@"objectID"] unsignedIntValue]);
        @try {
            for (LIBMTP_file_t *f = files; f; f = f->next) {
                NSDictionary *e = entry(f, source[@"path"]);
                download(device, e, [local stringByAppendingPathComponent:e[@"name"]], depth + 1);
            }
        } @finally {
            freeFiles(files);
        }
    } else {
        int fd = open(local.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0600);
        require(fd >= 0, @"localWrite");
        int status =
            LIBMTP_Get_File_To_File_Descriptor(device, [source[@"objectID"] unsignedIntValue], fd, progress, NULL);
        struct stat s;
        BOOL complete = fstat(fd, &s) == 0 && (uint64_t)s.st_size == [source[@"size"] unsignedLongLongValue];
        close(fd);
        require(status == 0 && complete, cancelled ? @"cancelled" : @"transfer");
    }
}
static NSDictionary *upload(LIBMTP_mtpdevice_t *device, NSString *local, NSDictionary *parent, NSString *name,
                            NSUInteger depth) {
    require(depth < 128 && validName(name), @"invalidName");
    if (cancelled)
        fail(@"cancelled");
    require(!findChild(device, parent, name), @"exists");
    struct stat s;
    require(lstat(local.fileSystemRepresentation, &s) == 0 && !S_ISLNK(s.st_mode), @"localRead");
    if (S_ISDIR(s.st_mode)) {
        NSDictionary *folder = makeFolder(device, parent, name);
        @try {
            NSError *error;
            NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:local error:&error];
            require(names != nil, @"localRead");
            for (NSString *child in names)
                upload(device, [local stringByAppendingPathComponent:child], folder, child, depth + 1);
        } @catch (NSException *error) {
            LIBMTP_Delete_Object(device, [folder[@"objectID"] unsignedIntValue]);
            @throw;
        }
        return folder;
    }
    require(S_ISREG(s.st_mode), @"localRead");
    int fd = open(local.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    require(fd >= 0, @"localRead");
    struct stat opened;
    if (fstat(fd, &opened) != 0 || opened.st_ino != s.st_ino || opened.st_dev != s.st_dev || !S_ISREG(opened.st_mode)) {
        close(fd);
        fail(@"localRead");
    }
    LIBMTP_file_t *f = LIBMTP_new_file_t();
    f->filename = strdup(name.UTF8String);
    f->filesize = s.st_size;
    f->filetype = LIBMTP_FILETYPE_UNKNOWN;
    f->parent_id = parentHandle(parent);
    f->storage_id = [parent[@"storageID"] unsignedIntValue];
    f->modificationdate = s.st_mtime;
    int status = LIBMTP_Send_File_From_File_Descriptor(device, fd, f, progress, NULL);
    close(fd);
    uint32_t object = f->item_id;
    NSDictionary *result = object ? entry(f, parent[@"path"]) : nil;
    LIBMTP_destroy_file_t(f);
    if (status != 0 || !object) {
        if (object)
            LIBMTP_Delete_Object(device, object);
        fail(cancelled ? @"cancelled" : @"transfer");
    }
    return result;
}
// Probe USB descriptors only: never claim an MTP interface while a transfer is active.
static NSArray *presence(void) {
    libusb_context *ctx = NULL;
    require(libusb_init(&ctx) == 0, @"usb");
    libusb_device **list;
    usleep(100000);
    ssize_t count = libusb_get_device_list(ctx, &list);
    NSMutableArray *result = [NSMutableArray array];
    LIBMTP_device_entry_t *known = NULL;
    int knownCount = 0;
    LIBMTP_Get_Supported_Devices_List(&known, &knownCount);
    for (ssize_t i = 0; i < count; i++) {
        struct libusb_device_descriptor d;
        if (libusb_get_device_descriptor(list[i], &d))
            continue;
        BOOL mtp = NO;
        for (int j = 0; j < knownCount; j++)
            if (known[j].vendor_id == d.idVendor && known[j].product_id == d.idProduct) {
                mtp = YES;
                break;
            }
        struct libusb_config_descriptor *config = NULL;
        if (libusb_get_active_config_descriptor(list[i], &config) == 0) {
            for (int j = 0; j < config->bNumInterfaces; j++)
                for (int k = 0; k < config->interface[j].num_altsetting; k++) {
                    const struct libusb_interface_descriptor *a = &config->interface[j].altsetting[k];
                    if (a->bInterfaceClass == 6 && a->bInterfaceSubClass == 1 && a->bInterfaceProtocol == 1)
                        mtp = YES;
                }
            libusb_free_config_descriptor(config);
        }
        if (mtp)
            [result addObject:transport(d.idVendor, d.idProduct, libusb_get_bus_number(list[i]),
                                        libusb_get_device_address(list[i]))];
    }
    libusb_free_device_list(list, 1);
    libusb_exit(ctx);
    return result;
}
static NSDictionary *execute(NSDictionary *request) {
    NSString *op = request[@"op"];
    require([op isKindOfClass:NSString.class], @"request");
    if ([op isEqual:@"presence"])
        return @{@"transports" : presence()};
    LIBMTP_raw_device_t *raw = NULL;
    int count = 0;
    LIBMTP_error_number_t status = LIBMTP_ERROR_NO_DEVICE_ATTACHED;
    // Darwin USB enumeration can initially be empty while its event source starts.
    // Retry discovery only, never replay a file operation.
    for (int attempt = 0; attempt < 3 && count == 0 && !cancelled; attempt++) {
        if (attempt) {
            free(raw);
            raw = NULL;
            usleep(150000);
        }
        status = LIBMTP_Detect_Raw_Devices(&raw, &count);
    }
    require(status == LIBMTP_ERROR_NONE || status == LIBMTP_ERROR_NO_DEVICE_ATTACHED, @"usb");
    NSMutableArray *devices = [NSMutableArray array];
    NSDictionary *result = nil;
    @try {
        for (int i = 0; i < count; i++) {
            NSString *tid = rawTransport(raw[i]);
            // The discovery result pins operations to a particular attachment; no wrong-device writes.
            if (![op isEqual:@"scan"] && request[@"transport"] && ![request[@"transport"] isEqual:tid])
                continue;
            LIBMTP_mtpdevice_t *device = NULL;
            for (int attempt = 0; attempt < 3 && !device && !cancelled; attempt++) {
                if (attempt)
                    usleep(200000 * attempt);
                device = LIBMTP_Open_Raw_Device_Uncached(&raw[i]);
            }
            if (!device) {
                if ([op isEqual:@"scan"])
                    [devices addObject:@{
                        @"serial" : tid,
                        @"transportID" : tid,
                        @"model" : str(raw[i].device_entry.product),
                        @"state" : @"unavailable",
                        @"storages" : @[]
                    }];
                continue;
            }
            @try {
                NSString *serial = owned(LIBMTP_Get_Serialnumber(device));
                if (!serial.length)
                    serial = tid;
                if ([op isEqual:@"scan"]) {
                    NSArray *stores = @[];
                    @try {
                        stores = storages(device);
                    } @catch (NSException *e) {
                    }
                    NSString *model = owned(LIBMTP_Get_Modelname(device));
                    if (!model.length)
                        model = str(raw[i].device_entry.product);
                    [devices addObject:@{
                        @"serial" : serial,
                        @"model" : model,
                        @"transportID" : tid,
                        @"state" : stores.count ? @"device" : @"locked",
                        @"storages" : stores
                    }];
                    continue;
                }
                require([serial isEqual:request[@"serial"]], @"deviceChanged");
                NSArray *stores = storages(device);
                require(stores.count, @"locked");
                NSString *path = normalize(request[@"path"] ?: @"/", stores);
                if ([op isEqual:@"list"] &&
                    ([path isEqual:@"/"] ||
                     [@[ @"/storage", @"/storage/emulated", @"/storage/self" ] containsObject:path])) {
                    NSMutableArray *items = [NSMutableArray array];
                    for (NSDictionary *s in stores)
                        [items addObject:@{
                            @"name" : [s[@"path"] lastPathComponent],
                            @"displayName" : s[@"label"],
                            @"path" : s[@"path"],
                            @"storageID" : s[@"id"],
                            @"objectID" : @0,
                            @"isDirectory" : @YES,
                            @"size" : @0,
                            @"modified" : @0
                        }];
                    result = @{@"entries" : items};
                    break;
                }
                if ([@[ @"mkdir", @"touch" ] containsObject:op]) {
                    NSDictionary *parent = resolve(device, [path stringByDeletingLastPathComponent], stores);
                    NSString *name = path.lastPathComponent;
                    if ([op isEqual:@"mkdir"])
                        result = @{@"entry" : makeFolder(device, parent, name)};
                    else {
                        NSString *local =
                            [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
                        require([[NSData data] writeToFile:local atomically:NO], @"localWrite");
                        @try {
                            result = @{@"entry" : upload(device, local, parent, name, 0)};
                        } @finally {
                            unlink(local.fileSystemRepresentation);
                        }
                    }
                    break;
                }
                NSDictionary *source = resolve(device, path, stores);
                if ([op isEqual:@"list"]) {
                    require([source[@"isDirectory"] boolValue], @"notFolder");
                    NSMutableArray *items = [NSMutableArray array];
                    LIBMTP_file_t *files = children(device, [source[@"storageID"] unsignedIntValue],
                                                    [source[@"objectID"] unsignedIntValue]);
                    @try {
                        for (LIBMTP_file_t *f = files; f; f = f->next) {
                            NSDictionary *e = entry(f, path);
                            [items addObject:e];
                        }
                    } @finally {
                        freeFiles(files);
                    }
                    result = @{@"entries" : items};
                } else if ([op isEqual:@"streamInfo"]) {
                    require(![source[@"isDirectory"] boolValue], @"notFile");
                    require(LIBMTP_Check_Capability(device, LIBMTP_DEVICECAP_GetPartialObject), @"unsupportedRead");
                    result = @{@"entry" : source};
                } else if ([op isEqual:@"read"]) {
                    require(![source[@"isDirectory"] boolValue], @"notFile");
                    require(LIBMTP_Check_Capability(device, LIBMTP_DEVICECAP_GetPartialObject), @"unsupportedRead");
                    for (NSString *key in @[ @"objectID", @"storageID", @"size", @"modified" ])
                        require([request[key] isKindOfClass:NSNumber.class] && [request[key] isEqual:source[key]],
                                @"fileChanged");
                    NSNumber *offset = request[@"offset"], *length = request[@"length"];
                    require([offset isKindOfClass:NSNumber.class] && [length isKindOfClass:NSNumber.class], @"range");
                    uint64_t start = offset.unsignedLongLongValue, size = [source[@"size"] unsignedLongLongValue];
                    int64_t amount = length.longLongValue;
                    require(offset.longLongValue >= 0 && start <= size && amount > 0 && amount <= 1024 * 1024 &&
                                offset.doubleValue == (double)start && length.doubleValue == (double)amount,
                            @"range");
                    unsigned char *bytes = NULL;
                    unsigned int count = 0;
                    @try {
                        require(LIBMTP_GetPartialObject(device, [source[@"objectID"] unsignedIntValue], start,
                                                        (uint32_t)MIN((uint64_t)amount, size - start), &bytes,
                                                        &count) == 0,
                                @"partialRead");
                        require(count <= (uint64_t)amount && count <= size - start && (count == 0 || bytes != NULL),
                                @"partialRead");
                        NSData *data = [NSData dataWithBytes:bytes length:count];
                        result = @{@"bytes" : [data base64EncodedStringWithOptions:0]};
                    } @finally {
                        free(bytes);
                    }
                } else if ([op isEqual:@"stat"])
                    result = @{@"entry" : source};
                else if ([op isEqual:@"pull"]) {
                    download(device, source, request[@"local"], 0);
                    result = @{};
                } else if ([op isEqual:@"push"]) {
                    require([source[@"isDirectory"] boolValue], @"notFolder");
                    result = @{
                        @"entry" : upload(device, request[@"local"], source,
                                          request[@"name"] ?: [request[@"local"] lastPathComponent], 0)
                    };
                } else {
                    uint32_t object = [source[@"objectID"] unsignedIntValue];
                    require(object != 0, @"storageRoot");
                    if ([op isEqual:@"delete"])
                        require(LIBMTP_Delete_Object(device, object) == 0, @"write");
                    else if ([op isEqual:@"rename"]) {
                        NSString *name = request[@"name"];
                        require(validName(name), @"invalidName");
                        NSDictionary *parent = resolve(device, [path stringByDeletingLastPathComponent], stores);
                        require(!findChild(device, parent, name), @"exists");
                        LIBMTP_file_t *f = LIBMTP_Get_Filemetadata(device, object);
                        require(f != NULL, @"read");
                        int status = LIBMTP_Set_File_Name(device, f, name.UTF8String);
                        LIBMTP_destroy_file_t(f);
                        require(status == 0, @"write");
                    } else if ([op isEqual:@"move"]) {
                        NSDictionary *target = resolve(device, request[@"target"], stores);
                        require([target[@"isDirectory"] boolValue], @"notFolder");
                        require(![target[@"path"] isEqual:path] &&
                                    ![target[@"path"] hasPrefix:[path stringByAppendingString:@"/"]],
                                @"recursive");
                        require(!findChild(device, target, source[@"name"]), @"exists");
                        require(LIBMTP_Check_Capability(device, LIBMTP_DEVICECAP_MoveObject), @"unsupportedMove");
                        require(LIBMTP_Move_Object(device, object, [target[@"storageID"] unsignedIntValue],
                                                   parentHandle(target)) == 0,
                                @"write");
                    } else
                        fail(@"request");
                    result = @{};
                }
                break;
            } @catch (NSException *error) {
                LIBMTP_Dump_Errorstack(device);
                @throw;
            } @finally {
                LIBMTP_Release_Device(device);
            }
        }
    } @finally {
        free(raw);
    }
    if ([op isEqual:@"scan"])
        return @{@"devices" : devices};
    require(result != nil, @"noDevice");
    return result;
}
int main(void) {
    @autoreleasepool {
        resultFD = dup(STDOUT_FILENO);
        dup2(STDERR_FILENO, STDOUT_FILENO);
        signal(SIGTERM, stopTransfer);
        signal(SIGINT, stopTransfer);
        LIBMTP_Init();
        LIBMTP_Set_Debug(0);
        @try {
            NSData *input = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
            require(input.length <= 1024 * 1024, @"request");
            NSDictionary *request = [NSJSONSerialization JSONObjectWithData:input options:0 error:nil];
            require([request isKindOfClass:NSDictionary.class], @"request");
            emit(@{@"result" : execute(request)});
            return 0;
        } @catch (NSException *error) {
            emit(@{@"error" : error.name});
            return 1;
        }
    }
}
