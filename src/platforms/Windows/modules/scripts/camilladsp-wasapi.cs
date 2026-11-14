using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

// Managed WASAPI endpoint reader.
//
// PowerShell cannot bind the MMDevice API: IMMDevice and IMMDeviceCollection are
// IUnknown-only interfaces, so member access on the COM wrapper answers "does not
// contain a method named ..." and the caller silently reads nothing. Declaring the
// interfaces here, in vtable order, is the only way to reach the documented members.
public sealed class CamillaDSPWasapi
{
    private const int DataFlowRender = 0;
    // WHY: eConsole (0) is the role the shipped getter read and what Sound settings calls the default device; eMultimedia can name a different endpoint.
    private const int RoleDefault = 0;
    private const int StateActive = 0x1;
    private const int StorageRead = 0;
    private const int FriendlyNamePropertyId = 14;
    private const ushort VariantStringPointer = 31;

    private static readonly Guid FriendlyNameFormat = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0");

    public string GetDefaultRenderFriendlyName()
    {
        if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            return null;
        }

        IMMDeviceEnumerator enumerator = CreateEnumerator();
        try
        {
            IMMDevice device;
            Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(DataFlowRender, RoleDefault, out device));
            try
            {
                return ReadFriendlyName(device);
            }
            finally
            {
                Marshal.ReleaseComObject(device);
            }
        }
        finally
        {
            Marshal.ReleaseComObject(enumerator);
        }
    }

    public string[] GetActiveRenderFriendlyNames()
    {
        if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            return new string[0];
        }

        IMMDeviceEnumerator enumerator = CreateEnumerator();
        try
        {
            IMMDeviceCollection collection;
            Marshal.ThrowExceptionForHR(enumerator.EnumAudioEndpoints(DataFlowRender, StateActive, out collection));
            try
            {
                uint count;
                Marshal.ThrowExceptionForHR(collection.GetCount(out count));
                List<string> names = new List<string>();
                for (uint index = 0; index < count; index++)
                {
                    IMMDevice device;
                    Marshal.ThrowExceptionForHR(collection.Item(index, out device));
                    try
                    {
                        names.Add(ReadFriendlyName(device));
                    }
                    finally
                    {
                        Marshal.ReleaseComObject(device);
                    }
                }

                return names.ToArray();
            }
            finally
            {
                Marshal.ReleaseComObject(collection);
            }
        }
        finally
        {
            Marshal.ReleaseComObject(enumerator);
        }
    }

    private static IMMDeviceEnumerator CreateEnumerator()
    {
        return (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
    }

    private static string ReadFriendlyName(IMMDevice device)
    {
        IPropertyStore store;
        Marshal.ThrowExceptionForHR(device.OpenPropertyStore(StorageRead, out store));
        try
        {
            PROPERTYKEY key = new PROPERTYKEY { fmtid = FriendlyNameFormat, pid = FriendlyNamePropertyId };
            PROPVARIANT value;
            Marshal.ThrowExceptionForHR(store.GetValue(ref key, out value));
            try
            {
                if (value.valueType != VariantStringPointer)
                {
                    throw new InvalidOperationException("PKEY_Device_FriendlyName is not a string");
                }

                return Marshal.PtrToStringUni(value.pointerValue);
            }
            finally
            {
                PropVariantClear(ref value);
            }
        }
        finally
        {
            Marshal.ReleaseComObject(store);
        }
    }

    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref PROPVARIANT value);

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private class MMDeviceEnumeratorComObject
    {
    }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);

        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);

        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);

        int RegisterEndpointNotificationCallback(IntPtr client);

        int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        int Activate(ref Guid interfaceId, int classContext, IntPtr activationParameters, [MarshalAs(UnmanagedType.IUnknown)] out object instance);

        int OpenPropertyStore(int access, out IPropertyStore properties);

        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);

        int GetState(out int state);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceCollection
    {
        int GetCount(out uint devices);

        int Item(uint index, out IMMDevice device);
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        int GetCount(out uint properties);

        int GetAt(uint index, out PROPERTYKEY key);

        int GetValue(ref PROPERTYKEY key, out PROPVARIANT value);

        int SetValue(ref PROPERTYKEY key, ref PROPVARIANT value);

        int Commit();
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROPERTYKEY
    {
        public Guid fmtid;

        public int pid;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROPVARIANT
    {
        public ushort valueType;

        public ushort reserved1;

        public ushort reserved2;

        public ushort reserved3;

        public IntPtr pointerValue;

        public int intValue;
    }
}
