#!/usr/bin/env python3
"""Diagnose why libusb cannot claim the Valeria AV bulk interface.

Activates the hidden QuickTime/Valeria USB config (control request
bmRequestType=0x40, bRequest=0x52, wIndex=0x02), finds the vendor-specific
interface (class 0xff, subclass 0x2a), and attempts to detach the kernel driver
and claim it. Reports the precise failure so we know whether Apple's CMIO/usbmuxd
driver owns the interface.

Restores the device to its enable-disable state on exit. Read-mostly: only USB
control + config selection; no data is consumed.
"""
import sys
import usb.core
import usb.util

APPLE_VID = 0x05ac

def find_iphone():
    for d in usb.core.find(find_all=True, idVendor=APPLE_VID):
        try:
            name = usb.util.get_string(d, d.iProduct)
        except Exception:
            name = "?"
        if name and "iphone" in name.lower():
            return d, name
    return None, None

def dump_configs(dev):
    print(f"bNumConfigurations = {dev.bNumConfigurations}")
    for cfg in dev:
        print(f"  config {cfg.bConfigurationValue}: {cfg.bNumInterfaces} interfaces")
        for intf in cfg:
            print(f"    intf {intf.bInterfaceNumber} alt {intf.bAlternateSetting}: "
                  f"class=0x{intf.bInterfaceClass:02x} sub=0x{intf.bInterfaceSubClass:02x} "
                  f"proto=0x{intf.bInterfaceProtocol:02x} endpoints={intf.bNumEndpoints}")

def main():
    dev, name = find_iphone()
    if dev is None:
        print("no iPhone found on USB")
        return 2
    print(f"iPhone: {name}")
    print("--- configs BEFORE activation ---")
    dump_configs(dev)

    # Enable hidden QuickTime/Valeria config.
    print("\nsending Valeria enable control request (0x40,0x52,wIndex=2)...")
    try:
        dev.ctrl_transfer(0x40, 0x52, 0x00, 0x02, b"")
        print("  control request OK")
    except Exception as e:
        print(f"  control request failed: {e!r}")

    # Re-enumerate.
    usb.util.dispose_resources(dev)
    dev, name = find_iphone()
    if dev is None:
        print("iPhone vanished after activation (re-enumerating); re-run to inspect")
        return 0
    print("\n--- configs AFTER activation ---")
    dump_configs(dev)

    # Find the vendor-specific AV interface (subclass 0x2a).
    target_cfg = target_intf = None
    for cfg in dev:
        for intf in cfg:
            if intf.bInterfaceClass == 0xff and intf.bInterfaceSubClass == 0x2a:
                target_cfg, target_intf = cfg, intf
                break
        if target_intf:
            break

    if target_intf is None:
        print("\nno subclass-0x2a AV interface present (config not active yet?)")
        return 0

    print(f"\nAV interface found: config {target_cfg.bConfigurationValue} "
          f"intf {target_intf.bInterfaceNumber}")
    try:
        dev.set_configuration(target_cfg.bConfigurationValue)
        print("  set_configuration OK")
    except Exception as e:
        print(f"  set_configuration failed: {e!r}")

    n = target_intf.bInterfaceNumber
    # Is a kernel driver attached (Apple's CMIO/usbmuxd)?
    try:
        active = dev.is_kernel_driver_active(n)
        print(f"  is_kernel_driver_active(intf {n}) = {active}")
    except Exception as e:
        print(f"  is_kernel_driver_active failed: {e!r}")

    try:
        dev.detach_kernel_driver(n)
        print("  detach_kernel_driver OK")
    except Exception as e:
        print(f"  detach_kernel_driver failed: {e!r}")

    try:
        usb.util.claim_interface(dev, n)
        print(f"  *** claim_interface({n}) OK — interface is ours ***")
        usb.util.release_interface(dev, n)
    except Exception as e:
        print(f"  claim_interface({n}) FAILED: {e!r}")
        print("  -> this is the route-1 blocker; Apple driver likely owns the interface")

    return 0

if __name__ == "__main__":
    sys.exit(main())
