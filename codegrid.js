// --------------------------------------------------------------------------------

const worldFile = 'worldgrid.json';
const gridPath = __dirname + '/tiles/';

// --------------------------------------------------------------------------------

function utfDecode(c) {
    if (c >= 93) c--;
    if (c >= 35) c--;
    return c - 32;
}

function loadjson(path, callback) {
    require('fs').readFile(path, (error, data) => {
        if (!error) callback(null, JSON.parse(data));
        else {
            if (error.code === 'ENOENT') {
                console.warn('File ' + path + ' not found.');
                callback('File ' + path + ' not found.');
            } else {
                console.warn(error.message);
                callback(error.message);
            }
        }
    });
}

const latlimit = (Math.atan((Math.exp(Math.PI) - Math.exp(-Math.PI)) / 2) / Math.PI) * 180;

function lon2tile(lon, zoom) {
    // http://javascript.about.com/od/problemsolving/a/modulobug.htm
    return Math.floor((((((lon + 180) / 360) % 1) + 1) % 1) * Math.pow(2, zoom));
}

function lat2tile(lat, zoom) {
    if (Math.abs(lat) >= latlimit) return -1;
    return Math.floor(((1 - Math.log(Math.tan((lat * Math.PI) / 180) + 1 / Math.cos((lat * Math.PI) / 180)) / Math.PI) / 2) * Math.pow(2, zoom));
}

// --------------------------------------------------------------------------------

let worldAttr;
const zList = [9, 13];
const jsonCache = {};
const cellzoom = 5;

// --------------------------------------------------------------------------------

const Grid = (tx, ty, zoom, json) => {
    if (!json.grid || !json.keys) {
        console.warn('Error in creating grid - no grid/keys attribute');
        return null;
    }

    const data = json.grid;
    const keys = json.keys;
    const size = json.grid.length;
    const attrs = json.data;

    function getAttr(x, y) {
        let dataY = data[y],
            dataYLen = dataY.length;
        if (dataYLen > 1 && dataYLen < 4) {
            let redir = parseInt(dataY);
            if (redir.isNaN || redir < 0 || redir >= size) {
                console.warn('Error in decoding compressed grid');
                return null;
            }
            dataY = data[redir];
            dataYLen = dataY.length;
        }
        let codeX = 0;
        if (dataYLen === size) codeX = dataY.charCodeAt(x);
        else if (dataYLen === 1) codeX = dataY.charCodeAt(0);
        else
            for (let pos = 0, x0 = x; pos < dataYLen - 1; pos += 2) {
                x0 -= utfDecode(dataY.charCodeAt(pos + 1));
                if (x0 < 0) {
                    codeX = dataY.charCodeAt(pos);
                    break;
                }
            }
        const idx = utfDecode(codeX);
        if (!idx.isNaN && keys.length > idx) {
            const key = keys[idx];
            if (key === '') return {};
            if (!attrs) {
                if (worldAttr[key] !== undefined) return worldAttr[key];
            } else if (attrs[key] !== undefined) return attrs[key];
        }
        console.warn('Error in decoding grid data.');
        return null;
    }

    return {
        x: tx,
        y: ty,
        zoom,
        getCode: (lat, lng, callback) => {
            const elezoom = Math.round(Math.log(size) / Math.log(2)) + zoom;
            const elex = tx * Math.pow(2, elezoom - zoom),
                eley = ty * Math.pow(2, elezoom - zoom);
            const x = lon2tile(lng, elezoom) - elex,
                y = lat2tile(lat, elezoom) - eley;
            if (!(x % 1 === 0) || !(y % 1 === 0) || x < 0 || y < 0 || x >= size || y >= size) {
                console.warn('Error in arguments to retrieve grid');
                callback('Error in input coordinates: out of range');
                return;
            }
            const attr = getAttr(x, y);
            if (attr !== null) {
                let code = 'None';
                if (attr.code !== undefined) {
                    code = attr.code;
                    if (attr.subcode !== undefined) code += ':' + attr.subcode;
                }
                callback(null, code);
            } else callback('Error reading geocode data');
        },
    };
};

// --------------------------------------------------------------------------------

const Zoomgrids = (zlist) => {
    const zoom = zlist[0];

    const nextZoomgrids = zlist.length > 1 ? Zoomgrids(zlist.slice(1)) : undefined;

    function handleJson(x, y, json, callback) {
        if (json[x] !== undefined && json[x][y] !== undefined) callback(null, Grid(x, y, zoom, json[x][y]));
        else {
            callback('Grid tile not found in loaded data.');
            console.warn('Grid tile ' + zoom.toString() + '/' + x.toString() + '/' + y.toString() + ' not found in loaded data.');
        }
    }

    const zGrids = [];
    function getGrid(x, y, callback) {
        for (let i = 0; i < zGrids.length; i++)
            if (zGrids[i].x === x && zGrids[i].y === y) {
                callback(null, zGrids[i]);
                return;
            }
        retrieveGrid(x, y, (error, rGrid) => {
            if (!error) {
                zGrids.push(rGrid);
                callback(null, rGrid);
            } else callback(error);
        });
    }

    function retrieveGrid(x, y, callback) {
        const cellx = Math.floor(x / Math.pow(2, zoom - cellzoom)),
            celly = Math.floor(y / Math.pow(2, zoom - cellzoom));
        if (jsonCache[cellx] !== undefined && jsonCache[cellx][celly] !== undefined && jsonCache[cellx][celly][zoom] !== undefined) handleJson(x, y, jsonCache[cellx][celly][zoom], callback);
        else
            loadjson(gridPath + cellx.toString() + '/' + celly.toString() + '.json', (error, json) => {
                if (!error) {
                    if (json[zoom] !== undefined) {
                        handleJson(x, y, json[zoom], callback);
                        if (jsonCache[cellx] === undefined) jsonCache[cellx] = {};
                        jsonCache[cellx][celly] = json;
                    } else {
                        callback('Zoom level ' + zoom.toString() + ' not in loaded data.');
                        console.warn('Zoom level ' + zoom.toString() + ' not in loaded data.');
                    }
                } else {
                    callback('Grid data loading error.');
                    console.warn('Error loading grid tile data: ' + error);
                }
            });
    }

    return {
        getCode: (lat, lng, callback) => {
            getGrid(lon2tile(lng, zoom), lat2tile(lat, zoom), (error, rGrid) => {
                if (!error)
                    rGrid.getCode(lat, lng, (error, result) => {
                        if (!error && result === '*') nextZoomgrids.getCode(lat, lng, callback);
                        else callback(error, result);
                    });
                else callback('Error getting grid data: ' + error);
            });
        },
    };
};

// --------------------------------------------------------------------------------

const CodeGrid = () => {
    const codegrid = {};
    const zoomGrids = Zoomgrids(zList);
    let worldGrid;
    let initialized = false;
    let initializing = true;
    const pendingcb = [];

    loadjson(gridPath + worldFile, (error, json) => {
        if (!error) {
            worldAttr = json.data;
            worldGrid = Grid(0, 0, 0, json);
            if (worldGrid) initialized = true;
            initializing = false;
            let param;
            while ((param = pendingcb.shift())) codegrid.getCode(param[0], param[1], param[2]);
        } else console.warn('Error loading geocoding data: ' + error);
    });

    codegrid.getCode = (lat, lng, callback) => {
        if (!initialized) {
            if (!initializing) {
                console.warn('Error : grid not initialized.');
                callback('Error: grid not initialized.');
            } else pendingcb.push([lat, lng, callback]);
            return;
        }
        worldGrid.getCode(lat, lng, (error, result) => {
            if (!error && result === '*') zoomGrids.getCode(lat, lng, callback);
            else callback(error, result);
        });
    };

    return codegrid;
};

// --------------------------------------------------------------------------------

const grid = CodeGrid();

function test(lat, lng, expect) {
    grid.getCode(lat, lng, (err, res) => {
        const str = `getCode (${lat}, ${lng})` + (expect ? ` [expect ${expect}]` : ` [expect Error]`);
        if (err) console.info(`${str} ==> Error: Returned: ${err}`);
        else {
            if (res === expect) console.info(`${str} ==> Success: returned ${res}`);
            else console.info(`${str} ==> Failure: returned ${res} instead of ${expect}`);
        }
    });
}

// --------------------------------------------------------------------------------

// test(22.502, 114.0527, 'cn:hk');
// test(20.895, 115.252, 'None');
// test(69.8202, -140.8063, 'us;ca');
// test(1000, 1000, null);

//

test(51.5074, -0.1278, 'gb'); // London
test(48.8566, 2.3522, 'fr'); // Paris
test(52.52, 13.405, 'de'); // Berlin
test(40.4168, -3.7038, 'es'); // Madrid
test(41.9028, 12.4964, 'it'); // Rome
test(38.7223, -9.1393, 'pt'); // Lisbon
test(59.3293, 18.0686, 'se'); // Stockholm
test(60.1699, 24.9384, 'fi'); // Helsinki
test(55.6761, 12.5683, 'dk'); // Copenhagen
test(52.2297, 21.0122, 'pl'); // Warsaw
test(50.0755, 14.4378, 'cz'); // Prague
test(47.4979, 19.0402, 'hu'); // Budapest
test(44.4268, 26.1025, 'ro'); // Bucharest
test(37.9838, 23.7275, 'gr'); // Athens
test(39.9334, 32.8597, 'tr'); // Ankara
test(55.7558, 37.6173, 'ru'); // Moscow
test(40.7128, -74.006, 'us'); // New York (proxy)
test(45.4215, -75.6972, 'ca'); // Ottawa
test(-15.7975, -47.8919, 'br'); // Brasilia
test(-34.6037, -58.3816, 'ar'); // Buenos Aires
test(19.4326, -99.1332, 'mx'); // Mexico City
test(35.6762, 139.6503, 'jp'); // Tokyo
test(37.5665, 126.978, 'kr'); // Seoul
test(39.9042, 116.4074, 'cn'); // Beijing
test(28.6139, 77.209, 'in'); // New Delhi
test(-33.8688, 151.2093, 'au'); // Sydney (proxy)
test(30.0444, 31.2357, 'eg'); // Cairo
test(-1.2921, 36.8219, 'ke'); // Nairobi
test(1.3521, 103.8198, 'sg'); // Singapore
test(64.1466, -21.9426, 'is'); // Reykjavik

// --------------------------------------------------------------------------------
