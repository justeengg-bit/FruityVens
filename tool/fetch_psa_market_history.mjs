import {mkdir, writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const outputPath = path.join(
  projectRoot,
  'assets',
  'data',
  'psa_market_history.json',
);

const PRICE_API =
  'https://openstat.psa.gov.ph/PXWeb/api/v1/en/DB/2M/2018/0042M4ARA07.px';
const PRICE_PAGE =
  'https://openstat.psa.gov.ph/PXWeb/pxweb/en/DB/DB__2M__2018/0042M4ARA07.px/';
const PRODUCTION_API =
  'https://openstat.psa.gov.ph/PXWeb/api/v1/en/DB/2E/CS/0072E4EVCP2.px';
const PRODUCTION_PAGE =
  'https://openstat.psa.gov.ph/PXWeb/pxweb/en/DB/DB__2E__CS/0072E4EVCP2.px/';

const geographies = {
  '000000000': {name: 'Philippines', level: 'national'},
  '100000000': {name: 'Northern Mindanao (Region X)', level: 'region'},
  '104300000': {name: 'Misamis Oriental', level: 'province'},
  '104305000': {name: 'Cagayan de Oro City', level: 'city'},
  '0': {name: 'Philippines', level: 'national'},
  '77': {name: 'Northern Mindanao (Region X)', level: 'region'},
  '82': {name: 'Misamis Oriental', level: 'province'},
};

const priceSeries = {
  '0': {fruitName: 'Avocado', variant: 'Avocado', priority: 0},
  '2': {fruitName: 'Banana', variant: 'Lakatan', priority: 1},
  '3': {fruitName: 'Banana', variant: 'Latundan', priority: 0},
  '4': {fruitName: 'Banana', variant: 'Saba', priority: 2},
  '7': {fruitName: 'Indian Mango', variant: 'Indian', priority: 0},
  '8': {fruitName: 'Mango Carabao', variant: 'Carabao/Kalabaw', priority: 0},
  '12': {fruitName: 'Mango', variant: 'Ripe mango', priority: 0},
  '16': {fruitName: 'Papaya', variant: 'Solo', priority: 0},
  '18': {fruitName: 'Pineapple', variant: 'Formosa', priority: 2},
  '19': {fruitName: 'Pineapple', variant: 'Hawaiian', priority: 0},
  '20': {fruitName: 'Pineapple', variant: 'General', priority: 1},
  '21': {fruitName: 'Grapes', variant: 'General', priority: 1},
  '22': {fruitName: 'Grapes', variant: 'Seedless', priority: 0},
  '23': {fruitName: 'Grapes', variant: 'With seeds', priority: 2},
  '28': {fruitName: 'Pomelo', variant: 'Pomelo', priority: 0},
  '29': {fruitName: 'Dalandan', variant: 'Dalandan', priority: 0},
  '30': {fruitName: 'Orange', variant: 'Sintones', priority: 0},
  '32': {fruitName: 'Calamansi', variant: 'Loose', priority: 0},
  '33': {fruitName: 'Apple', variant: 'Red Delicious', priority: 0},
  '35': {fruitName: 'Watermelon', variant: 'Pakwan', priority: 0},
};

const productionSeries = {
  '0': {fruitName: 'Banana', variant: 'All banana', priority: 0},
  '7': {fruitName: 'Calamansi', variant: 'Calamansi', priority: 0},
  '8': {fruitName: 'Mango', variant: 'All mango', priority: 0},
  '9': {fruitName: 'Mango Carabao', variant: 'Carabao', priority: 0},
  '11': {fruitName: 'Indian Mango', variant: 'Indian', priority: 0},
  '13': {fruitName: 'Pineapple', variant: 'Pineapple', priority: 0},
  '20': {fruitName: 'Avocado', variant: 'Avocado', priority: 0},
  '28': {fruitName: 'Dalandan', variant: 'Dalandan', priority: 0},
  '29': {fruitName: 'Dragon Fruit', variant: 'Dragon fruit', priority: 0},
  '31': {fruitName: 'Durian', variant: 'Durian', priority: 0},
  '34': {fruitName: 'Grapes', variant: 'All grapes', priority: 0},
  '46': {fruitName: 'Lemon', variant: 'Lemon', priority: 0},
  '53': {fruitName: 'Mangosteen', variant: 'Mangosteen', priority: 0},
  '61': {fruitName: 'Orange', variant: 'Orange', priority: 0},
  '63': {fruitName: 'Papaya', variant: 'All papaya', priority: 0},
  '68': {fruitName: 'Pear', variant: 'Pears', priority: 0},
  '70': {fruitName: 'Pomelo', variant: 'Pomelo', priority: 0},
  '81': {fruitName: 'Watermelon', variant: 'Watermelon', priority: 0},
};

function variableMap(metadata, code) {
  const variable = metadata.variables.find((item) => item.code === code);
  if (!variable) {
    throw new Error(`PSA metadata is missing ${code}.`);
  }
  return new Map(
    variable.values.map((value, index) => [value, variable.valueTexts[index]]),
  );
}

async function getJson(url, options = {}) {
  const response = await fetch(url, options);
  if (!response.ok) {
    throw new Error(`${response.status} ${response.statusText} from ${url}`);
  }
  return JSON.parse((await response.text()).replace(/^\uFEFF/, ''));
}

async function queryPxWeb(url, query) {
  return getJson(url, {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({query, response: {format: 'json'}}),
  });
}

function numericValue(raw) {
  if (raw == null || raw === '..' || raw === '...') {
    return null;
  }
  const value = Number(String(raw).replaceAll(',', ''));
  return Number.isFinite(value) ? value : null;
}

function cleanCommodity(value) {
  return value.replace(/\s+/g, ' ').trim();
}

async function retailPriceRecords(importedAt) {
  const metadata = await getJson(PRICE_API);
  const commodityNames = variableMap(metadata, 'Commodity');
  const yearNames = variableMap(metadata, 'Year');
  const periodNames = variableMap(metadata, 'Period');
  const years = [...yearNames.keys()].filter((code) => {
    const year = Number(yearNames.get(code));
    return year >= 2018 && year <= 2025;
  });
  const periods = [...periodNames.keys()].filter(
    (code) => periodNames.get(code) !== 'Annual',
  );
  const result = await queryPxWeb(PRICE_API, [
    {
      code: 'Geolocation',
      selection: {
        filter: 'item',
        values: ['000000000', '100000000', '104300000', '104305000'],
      },
    },
    {
      code: 'Commodity',
      selection: {filter: 'item', values: Object.keys(priceSeries)},
    },
    {code: 'Year', selection: {filter: 'item', values: years}},
    {code: 'Period', selection: {filter: 'item', values: periods}},
  ]);

  const records = [];
  for (const row of result.data) {
    const [geographyCode, commodityCode, yearCode, periodCode] = row.key;
    const value = numericValue(row.values[0]);
    if (value == null) continue;
    const config = priceSeries[commodityCode];
    const geography = geographies[geographyCode];
    const year = Number(yearNames.get(yearCode));
    const month = periods.indexOf(periodCode) + 1;
    records.push({
      seriesKey: `psa_retail_${geographyCode}_${commodityCode}`,
      fruitName: config.fruitName,
      variant: config.variant,
      metric: 'retail_price',
      geography: geography.name,
      geographyLevel: geography.level,
      periodStart: `${year}-${String(month).padStart(2, '0')}-01`,
      periodGranularity: 'month',
      value,
      unit: 'PHP/kg',
      sourceAgency: 'Philippine Statistics Authority',
      sourceTable: '2M4ARA07',
      sourceUrl: PRICE_PAGE,
      sourceCommodity: cleanCommodity(commodityNames.get(commodityCode)),
      seriesPriority: config.priority,
      importedAt,
    });
  }
  return records;
}

async function productionRecords(importedAt) {
  const metadata = await getJson(PRODUCTION_API);
  const cropNames = variableMap(metadata, 'Crop');
  const yearNames = variableMap(metadata, 'Year');
  const periodNames = variableMap(metadata, 'Period');
  const years = [...yearNames.keys()].filter((code) => {
    const year = Number(yearNames.get(code));
    return year >= 2010 && year <= 2025;
  });
  const quarterCodes = [...periodNames.keys()].filter((code) =>
    /^Quarter[1-4]$/.test(periodNames.get(code)),
  );
  const result = await queryPxWeb(PRODUCTION_API, [
    {
      code: 'Crop',
      selection: {filter: 'item', values: Object.keys(productionSeries)},
    },
    {
      code: 'Geolocation',
      selection: {filter: 'item', values: ['0', '77', '82']},
    },
    {code: 'Year', selection: {filter: 'item', values: years}},
    {code: 'Period', selection: {filter: 'item', values: quarterCodes}},
  ]);

  const quarterMonth = {Quarter1: 1, Quarter2: 4, Quarter3: 7, Quarter4: 10};
  const records = [];
  for (const row of result.data) {
    const [cropCode, geographyCode, yearCode, periodCode] = row.key;
    const value = numericValue(row.values[0]);
    if (value == null) continue;
    const config = productionSeries[cropCode];
    const geography = geographies[geographyCode];
    const year = Number(yearNames.get(yearCode));
    const month = quarterMonth[periodNames.get(periodCode)];
    records.push({
      seriesKey: `psa_production_${geographyCode}_${cropCode}`,
      fruitName: config.fruitName,
      variant: config.variant,
      metric: 'production_volume',
      geography: geography.name,
      geographyLevel: geography.level,
      periodStart: `${year}-${String(month).padStart(2, '0')}-01`,
      periodGranularity: 'quarter',
      value,
      unit: 'metric tons',
      sourceAgency: 'Philippine Statistics Authority',
      sourceTable: '2E4EVCP2',
      sourceUrl: PRODUCTION_PAGE,
      sourceCommodity: cleanCommodity(cropNames.get(cropCode)),
      seriesPriority: config.priority,
      importedAt,
    });
  }
  return records;
}

const importedAt = new Date().toISOString();
const records = [
  ...(await retailPriceRecords(importedAt)),
  ...(await productionRecords(importedAt)),
].sort((a, b) =>
  [a.metric, a.fruitName, a.seriesKey, a.periodStart]
    .join('|')
    .localeCompare([b.metric, b.fruitName, b.seriesKey, b.periodStart].join('|')),
);

const document = {
  datasetVersion: 'psa-openstat-2010-2025-v1',
  importedAt,
  location: 'Cagayan de Oro City',
  records,
  sources: [
    {
      agency: 'Philippine Statistics Authority',
      table: '2M4ARA07',
      title: 'Fruits: Retail Prices of Agricultural Commodities',
      frequency: 'monthly',
      coverage: '2018-2025',
      url: PRICE_PAGE,
    },
    {
      agency: 'Philippine Statistics Authority',
      table: '2E4EVCP2',
      title: 'Fruit Crops: Volume of Production',
      frequency: 'quarterly',
      coverage: '2010-2025',
      url: PRODUCTION_PAGE,
    },
  ],
};

await mkdir(path.dirname(outputPath), {recursive: true});
await writeFile(outputPath, `${JSON.stringify(document)}\n`, 'utf8');
console.log(`Wrote ${records.length} PSA records to ${outputPath}`);
