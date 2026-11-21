"""Build the receipt installer UI without the retired paired-sharing agent."""
from pathlib import Path
import exe_metadata


def build(root, stage, compiler):
    source = root / 'src/sharing'
    common = [source / name for name in ('ShareCrypto.cs', 'ReceiptPaths.cs')]
    refs = [name + '.dll' for name in (
        'System.Web.Extensions', 'System.Security', 'System.Windows.Forms',
        'System.Drawing', 'System.Net.Http', 'System.IO.Compression')]
    version = (root / 'VERSION').read_text().strip()
    info = exe_metadata.assembly_info(root / 'build/SharingAssemblyInfo.cs', 'GFW8LG Receipt Installer',
                                      'Verified receipt installation interface', version)
    compiler.compile(['/target:library', '/out:' + str(stage / 'Sharing.dll'),
                    *map(str, common), str(source / 'ReceiptInstallerWindow.cs'), str(source / 'MetroChrome.cs'), str(source / 'ReceiptFolderPicker.cs'), str(info)], refs)
    return [stage / 'Sharing.dll']
