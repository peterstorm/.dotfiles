/**
 * Voyage AI embedding client
 *
 * Thin HTTP client for generating embeddings via Voyage AI API.
 * All functions are pure (no classes) following functional core pattern.
 */

const VOYAGE_API_URL = 'https://api.voyageai.com/v1/embeddings';
const VOYAGE_MODEL = 'voyage-3.5-lite';
const EMBEDDING_DIMENSIONS = 1024;

/**
 * Response structure from Voyage API
 */
type VoyageResponse = {
  data: Array<{
    embedding: number[];
    index: number;
  }>;
  model?: string;
  usage?: {
    total_tokens: number;
  };
};

/**
 * Error types for Voyage API failures
 */
export type VoyageError =
  | { type: 'network'; message: string }
  | { type: 'auth'; message: string; status: number }
  | { type: 'rate_limit'; message: string; status: number }
  | { type: 'api_error'; message: string; status: number }
  | { type: 'invalid_response'; message: string };

/**
 * Check if Voyage API is available (API key present and non-empty).
 * Does not make network calls - only validates key format.
 *
 * @param apiKey - Voyage API key (optional)
 * @returns true if key is a non-empty string
 */
export function isVoyageAvailable(apiKey: string | undefined): boolean {
  return typeof apiKey === 'string' && apiKey.trim().length > 0;
}

/**
 * Embed multiple texts using Voyage AI API.
 * Returns Float64Array for each input text, preserving input order.
 *
 * @param texts - Array of texts to embed (readonly for immutability)
 * @param apiKey - Voyage API key
 * @returns Promise of Float64Array for each text
 * @throws Error with descriptive message on any failure
 */
export async function embedTexts(
  texts: readonly string[],
  apiKey: string
): Promise<Float64Array[]> {
  if (texts.length === 0) {
    return [];
  }

  if (!isVoyageAvailable(apiKey)) {
    throw new Error('Voyage API key is required and must be non-empty');
  }

  const requestBody = {
    model: VOYAGE_MODEL,
    input: texts,
    input_type: 'document',
  };

  let response: Response;

  try {
    response = await fetch(VOYAGE_API_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${apiKey}`,
      },
      body: JSON.stringify(requestBody),
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown network error';
    throw new Error(`Network failure calling Voyage API: ${message}`);
  }

  // Handle HTTP errors
  if (!response.ok) {
    let errorMessage: string;
    try {
      const errorBody = await response.json();
      errorMessage = errorBody.error?.message || errorBody.message || 'Unknown error';
    } catch {
      errorMessage = response.statusText || 'Unknown error';
    }

    if (response.status === 401 || response.status === 403) {
      throw new Error(`Voyage API authentication failed (${response.status}): ${errorMessage}`);
    }

    if (response.status === 429) {
      throw new Error(`Voyage API rate limit exceeded (429): ${errorMessage}`);
    }

    throw new Error(`Voyage API error (${response.status}): ${errorMessage}`);
  }

  // Parse and validate response
  let data: VoyageResponse;
  try {
    data = await response.json();
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Invalid JSON';
    throw new Error(`Malformed response from Voyage API: ${message}`);
  }

  if (!data.data || !Array.isArray(data.data)) {
    throw new Error('Malformed response from Voyage API: missing or invalid data field');
  }

  if (data.data.length !== texts.length) {
    throw new Error(
      `Malformed response from Voyage API: expected ${texts.length} embeddings, got ${data.data.length}`
    );
  }

  // Convert to Float64Array and validate dimensions
  try {
    const embeddings = data.data
      .sort((a, b) => a.index - b.index) // Ensure correct order
      .map((item) => {
        if (!Array.isArray(item.embedding)) {
          throw new Error('Malformed response: embedding is not an array');
        }
        if (item.embedding.length !== EMBEDDING_DIMENSIONS) {
          throw new Error(
            `Malformed response: expected ${EMBEDDING_DIMENSIONS} dimensions, got ${item.embedding.length}`
          );
        }
        return new Float64Array(item.embedding);
      });

    return embeddings;
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown error';
    throw new Error(`Failed to process embeddings: ${message}`);
  }
}
