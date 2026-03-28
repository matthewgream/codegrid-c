
Embedded C version of codegrid-js (https://github.com/hlaw/codegrid-js)

1. bitpacked and compressed tables, reducing compilation size down to ~900K to ~1.7MB depending upon options
2. no UTF8, JSON or other complexities: native 'C' structs and data, for super simplified lookup code
3. optional compile zoom=9 only, for lower footprint and still sufficient lookup resolution

```
root@workshop:/opt/codegrid# bzip2 -d < codegrid_tiles.tar.bz2 | tar xf -
root@workshop:/opt/codegrid# du -sh tiles
11M     tiles
root@workshop:/opt/codegrid# ./gentiles.sh tiles codegrid_tiles.h
Found 153 JSON files in 'tiles'
Encoding _cgrd bitstream (7354 rows, 77737 values)...
  _cgrd bitstream: 51,222 bytes
Encoding _cgrb bitstream (824336 values)...
  _cgrb bitstream: 716,466 bytes
  Constant: num_attrs=0, attrs_off=536
  Profiles: 2886
  Zoom 9: 4311 entries
  Zoom 13: 81697 entries

  _cgz: was 1,720,160 bytes
  profiles: 20,202 bytes (2886 × 7)
  z9 table: 43,110 bytes (4311 × 10)
  z13 table: 816,970 bytes (81697 × 10)
  new zoom total: 880,282 bytes (saved 839,878)

  TOTAL: ~1,697,245 bytes (1657 KB)

Generated -> codegrid_tiles.h
Done.
root@workshop:/opt/codegrid# gcc -O3 codegrid.c -o codegrid -lm
root@workshop:/opt/codegrid# ls -lh codegrid
-rwxr-xr-x 1 root root 1.7M Mar 28 09:09 codegrid
root@workshop:/opt/codegrid# gcc -O3 codegrid.c -DZOOM9_ONLY -o codegrid -lm
root@workshop:/opt/codegrid# ls -lh codegrid
-rwxr-xr-x 1 root root 882K Mar 28 09:10 codegrid
root@workshop:/opt/codegrid# ./codegrid
[OK] London         ( 51.5074,  -0.1278) => gb       (expect gb)
[OK] Paris          ( 48.8566,   2.3522) => fr       (expect fr)
[OK] Berlin         ( 52.5200,  13.4050) => de       (expect de)
[OK] Madrid         ( 40.4168,  -3.7038) => es       (expect es)
[OK] Rome           ( 41.9028,  12.4964) => it       (expect it)
[OK] Lisbon         ( 38.7223,  -9.1393) => pt       (expect pt)
[OK] Stockholm      ( 59.3293,  18.0686) => se       (expect se)
[OK] Helsinki       ( 60.1699,  24.9384) => fi       (expect fi)
[OK] Copenhagen     ( 55.6761,  12.5683) => dk       (expect dk)
[OK] Warsaw         ( 52.2297,  21.0122) => pl       (expect pl)
[OK] Prague         ( 50.0755,  14.4378) => cz       (expect cz)
[OK] Budapest       ( 47.4979,  19.0402) => hu       (expect hu)
[OK] Bucharest      ( 44.4268,  26.1025) => ro       (expect ro)
[OK] Athens         ( 37.9838,  23.7275) => gr       (expect gr)
[OK] Ankara         ( 39.9334,  32.8597) => tr       (expect tr)
[OK] Moscow         ( 55.7558,  37.6173) => ru       (expect ru)
[OK] New York       ( 40.7128, -74.0060) => us       (expect us)
[OK] Ottawa         ( 45.4215, -75.6972) => ca       (expect ca)
[OK] Brasilia       (-15.7975, -47.8919) => br       (expect br)
[OK] Buenos Aires   (-34.6037, -58.3816) => ar       (expect ar)
[OK] Mexico City    ( 19.4326, -99.1332) => mx       (expect mx)
[OK] Tokyo          ( 35.6762, 139.6503) => jp       (expect jp)
[OK] Seoul          ( 37.5665, 126.9780) => kr       (expect kr)
[OK] Beijing        ( 39.9042, 116.4074) => cn       (expect cn)
[OK] New Delhi      ( 28.6139,  77.2090) => in       (expect in)
[OK] Sydney         (-33.8688, 151.2093) => au       (expect au)
[OK] Cairo          ( 30.0444,  31.2357) => eg       (expect eg)
[OK] Nairobi        ( -1.2921,  36.8219) => ke       (expect ke)
[OK] Singapore      (  1.3521, 103.8198) => sg       (expect sg)
[OK] Reykjavik      ( 64.1466, -21.9426) => is       (expect is)

30 total, 30 passed, 0 failed

```
