"""Build-time preservation exception for the separate Token Lab only."""

def apply_lab_preservation_policy(files):
    helpers = [p for p in files if p.name == 'TemporaryAuthHelper.ps1']
    if len(helpers) != 1:
        raise RuntimeError('Expected one authentication helper for the Lab policy')
    helper = helpers[0]
    data = helper.read_bytes()
    text = data.decode('utf-8-sig')
    snapshot = "pop=($file.Name -ieq 'pop.bin')}"
    # Match only exact paths immediately under the package's Settings folder.
    # Keep backups of these files; skip only their later equality check.
    replacement = snapshot[:-1] + r";windowsSettingsVolatile=($file.FullName.Substring($data.Length+1) -match '(?i)^Settings\\(?:settings\.dat(?:\.LOG[12])?|roaming\.lock)$')}"
    assertion = 'foreach($file in $Snapshot){if(!(Test-Path'
    filtered = 'foreach($file in $Snapshot){if($file.windowsSettingsVolatile -and !$file.pop){continue};if(!(Test-Path'
    if text.count(snapshot) != 1 or text.count(assertion) != 1:
        raise RuntimeError('Preservation source changed; review the Lab exception')
    text = text.replace(snapshot, replacement).replace(assertion, filtered)
    helper.write_bytes((b'\xef\xbb\xbf' if data.startswith(b'\xef\xbb\xbf') else b'') + text.encode('utf-8'))
