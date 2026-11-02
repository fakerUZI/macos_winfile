#import <AppKit/AppKit.h>

@interface LeafFilesDockTile : NSObject <NSDockTilePlugIn>
@property (weak) NSDockTile *tile;
@end

@implementation LeafFilesDockTile
- (void)setDockTile:(NSDockTile *)tile {
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
    self.tile = tile;
    if (!tile) return;
    [[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh:)
        name:@"local.winfile.mac.DockIconChanged" object:nil];
    [self refresh:nil];
}
- (void)refresh:(NSNotification *)notification {
    (void)notification;
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"local.winfile.mac"];
    NSString *choice = [defaults stringForKey:@"Appearance.DockIcon.v1"];
    NSURL *app = [[[[NSBundle bundleForClass:self.class] bundleURL] URLByDeletingLastPathComponent]
                  URLByDeletingLastPathComponent];
    app = [app URLByDeletingLastPathComponent];
    NSString *name = [choice isEqualToString:@"original"] ? @"ClassicAppIcon.icns" : @"AppIcon.icns";
    NSURL *icon = [[app URLByAppendingPathComponent:@"Contents/Resources"] URLByAppendingPathComponent:name];
    NSImage *image = [[NSImage alloc] initWithContentsOfURL:icon];
    if (!image || !self.tile) return;
    NSImageView *view = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 128, 128)];
    view.imageScaling = NSImageScaleProportionallyUpOrDown;
    view.image = image;
    self.tile.contentView = view;
    [self.tile display];
}
@end
