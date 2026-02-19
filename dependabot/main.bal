// Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/crypto;
import ballerina/data.jsondata;
import ballerina/data.yaml;
import ballerina/file;
import ballerinax/github;
import ballerina/http;
import ballerina/io;
import ballerina/lang.regexp;
import ballerina/os;

// Logging utility function for structured output
isolated function print(string message, string level, int indentation) {
    string spaces = string:'join("", from int i in 0 ..< indentation select "\t");
    io:println(string `${spaces}[${level}] ${message}`);
}

// Versioning strategy types
const RELEASE_TAG = "release-tag";
const FILE_BASED = "file-based";
const ROLLOUT_BASED = "rollout-based";

// Repository record type
type Repository record {|
    string vendor;
    string api;
    string owner;
    string repo;
    string name;
    string lastVersion;
    string specPath;
    string releaseAssetName;
    string baseUrl;
    string documentationUrl;
    string description;
    string[] tags;
    string versioningStrategy = RELEASE_TAG;
    string? branch = ();
    string? connectorRepo = ();
    string? lastContentHash = ();
|};

// Update result record
type UpdateResult record {|
    Repository repo;
    string oldVersion;
    string newVersion;
    string apiVersion;
    string downloadUrl;
    string localPath;
    boolean contentChanged;
    string updateType;
|};

// Check for version updates
function hasVersionChanged(string oldVersion, string newVersion) returns boolean {
    return oldVersion != newVersion;
}

// Check for content updates
function hasContentChanged(string? oldHash, string newHash) returns boolean {
    if oldHash is () || oldHash == "" {
        return true;
    }
    return oldHash != newHash;
}

// Calculate SHA-256 hash of content
function calculateHash(string content) returns string {
    byte[] contentBytes = content.toBytes();
    byte[] hashBytes = crypto:hashSha256(contentBytes);
    return hashBytes.toBase16();
}

// Extract rollout number from path
function extractRolloutNumber(string path) returns string|error {
    string[] parts = regexp:split(re `/`, path);
    foreach int i in 0 ..< parts.length() {
        if parts[i] == "Rollouts" && i + 1 < parts.length() {
            return parts[i + 1];
        }
    }
    return error("Could not extract rollout number from path");
}

// List directory contents from GitHub
function listGitHubDirectory(string owner, string repo, string branch, string path, string token) returns string[]|error {
    string baseUrl = "https://api.github.com";
    string apiPath = string `/repos/${owner}/${repo}/contents/${path}?ref=${branch}`;

    http:Client httpClient = check new (baseUrl);
    map<string> headers = {
        "Authorization": string `Bearer ${token}`,
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28"
    };

    http:Response response = check httpClient->get(apiPath, headers);

    if response.statusCode != 200 {
        return error(string `Failed to list directory: HTTP ${response.statusCode}`);
    }

    json|error content = response.getJsonPayload();
    if content is error {
        return error("Failed to parse directory listing");
    }

    if content is json[] {
        string[] names = [];
        foreach json item in content {
            if item is map<json> {
                json? nameJson = item["name"];
                if nameJson is string {
                    names.push(nameJson);
                }
            }
        }
        return names;
    }

    return error("Unexpected response format from GitHub API");
}

// Find latest rollout number in a directory
function findLatestRollout(string owner, string repo, string branch, string basePath, string token) returns string|error {
    print(string `Searching for rollouts in ${basePath}...`, "Info", 1);

    string[] contents = check listGitHubDirectory(owner, repo, branch, basePath, token);

    int maxRollout = 0;
    foreach string item in contents {
        int|error rolloutNum = int:fromString(item);
        if rolloutNum is int && rolloutNum > maxRollout {
            maxRollout = rolloutNum;
        }
    }

    if maxRollout == 0 {
        return error("No rollout directories found");
    }

    print(string `Found latest rollout: ${maxRollout}`, "Info", 1);
    return maxRollout.toString();
}

// Extract version from OpenAPI spec using proper YAML/JSON parsing
function extractApiVersion(string content) returns string|error {
    // Detect file format
    string trimmedContent = content.trim();
    boolean isJson = trimmedContent.startsWith("{") || trimmedContent.startsWith("[");

    json parsedData = {};

    if isJson {
        json|error jsonResult = jsondata:parseString(content);
        if jsonResult is error {
            return error(string `Failed to parse JSON: ${jsonResult.message()}`);
        }
        parsedData = jsonResult;
    } else {
        json|error yamlResult = yaml:parseString(content);
        if yamlResult is error {
            return error(string `Failed to parse YAML: ${yamlResult.message()}`);
        }
        parsedData = yamlResult;
    }

    // Extract version from info.version field
    if parsedData is map<json> {
        json? infoField = parsedData["info"];
        if infoField is () {
            return error("'info' field not found in OpenAPI spec");
        }

        if infoField is map<json> {
            json? versionField = infoField["version"];
            if versionField is () {
                return error("'version' field not found under 'info' in OpenAPI spec");
            }

            if versionField is string {
                return versionField;
            } else {
                return error("'version' field is not a string");
            }
        } else {
            return error("'info' field is not a map");
        }
    } else {
        return error("Parsed data is not a map");
    }
}

// Download OpenAPI spec from release asset
function downloadFromGitHubReleaseAsset(github:Client githubClient, string owner, string repo,
        string assetName, string tagName) returns string|error {

    print(string `Searching release assets for ${assetName}...`, "Info", 1);

    github:Release release = check githubClient->/repos/[owner]/[repo]/releases/tags/[tagName]();
    github:ReleaseAsset[]? assets = release.assets;

    if assets is () {
        return error("No assets found in release");
    }

    foreach github:ReleaseAsset asset in assets {
        if asset.name != assetName {
            continue;
        }
        print(string `Found in release assets`, "Info", 1);

        string downloadUrl = asset.browser_download_url;
        http:Client httpClient = check new (downloadUrl);
        http:Response response = check httpClient->get("");
        if response.statusCode != 200 {
            return error(string `Failed to download asset: HTTP ${response.statusCode}`);
        }
        return check getTextFromResponse(response);
    }

    return error(string `Asset '${assetName}' not found in release`);
}

// Download OpenAPI spec from raw GitHub URL (fallback)
function downloadFromGitHubRawLink(string owner, string repo,
        string tagName, string specPath) returns string|error {

    string baseUrl = "https://raw.githubusercontent.com";
    string path = string `/${owner}/${repo}/${tagName}/${specPath}`;
    print(string `Downloading from raw GitHub URL: ${baseUrl}${path}`, "Info", 1);

    http:Client httpClient = check new (baseUrl);
    http:Response response = check httpClient->get(path);

    if response.statusCode != 200 {
        return error(string `Failed to download: HTTP ${response.statusCode} from ${baseUrl}${path}`);
    }

    return check getTextFromResponse(response);
}

// Helper: extract text content from HTTP response
isolated function getTextFromResponse(http:Response response) returns string|error {
    string|byte[]|error content = response.getTextPayload();
    if content is error {
        return error("Failed to get content from response");
    }
    if content is string {
        return content;
    }
    return check string:fromBytes(content);
}

// Download OpenAPI spec
function downloadSpec(github:Client githubClient, string owner, string repo,
        string assetName, string tagName, string specPath) returns string|error {

    print(string `Downloading ${assetName}...`, "Info", 1);

    string|error assetContent = downloadFromGitHubReleaseAsset(githubClient, owner, repo, assetName, tagName);
    if assetContent is string {
        return assetContent;
    }

    print(string `Not in release assets, falling back to raw link...`, "Info", 1);
    return downloadFromGitHubRawLink(owner, repo, tagName, specPath);
}

// Download spec directly from branch
function downloadSpecFromBranch(string owner, string repo, string branch, string specPath) returns string|error {
    print(string `Downloading ${specPath} from ${branch} branch...`, "Info", 1);

    string baseUrl = string `https://raw.githubusercontent.com`;
    string path = string `/${owner}/${repo}/${branch}/${specPath}`;

    http:Client httpClient = check new (baseUrl);
    http:Response response = check httpClient->get(path);

    if response.statusCode != 200 {
        return error(string `Failed to download: HTTP ${response.statusCode} from ${baseUrl}${path}`);
    }

    string|byte[] content = check response.getTextPayload();
    return content is string ? content : string:fromBytes(content);
}

// Detect file extension from content format
function getFileExtension(string content) returns string {
    string trimmedContent = content.trim();
    boolean isJson = trimmedContent.startsWith("{") || trimmedContent.startsWith("[");
    return isJson ? "json" : "yaml";
}

// Check if a spec file already exists in the directory (either .json or .yaml)
function specFileExists(string dirPath) returns boolean|error {
    if !check file:test(dirPath, file:EXISTS) {
        return false;
    }

    string jsonPath = dirPath + "/openapi.json";
    string yamlPath = dirPath + "/openapi.yaml";

    boolean jsonExists = check file:test(jsonPath, file:EXISTS);
    boolean yamlExists = check file:test(yamlPath, file:EXISTS);

    return jsonExists || yamlExists;
}

// Save spec to file - preserves original format (JSON or YAML)
function saveSpec(string content, string localPath) returns error? {
    string dirPath = check file:parentPath(localPath);
    if !check file:test(dirPath, file:EXISTS) {
        check file:createDir(dirPath, file:RECURSIVE);
    }

    check io:fileWriteString(localPath, content);
    print(string `Saved to ${localPath}`, "Info", 1);
    return;
}

// Create metadata.json file
function createMetadataFile(Repository repo, string version, string dirPath) returns error? {
    json metadata = {
        "name": repo.name,
        "baseUrl": repo.baseUrl,
        "documentationUrl": repo.documentationUrl,
        "description": repo.description,
        "tags": repo.tags
    };

    string metadataPath = string `${dirPath}/.metadata.json`;
    check io:fileWriteJson(metadataPath, metadata);
    print(string `Created metadata at ${metadataPath}`, "Info", 1);
    return;
}

// Get current repository info from git
function getCurrentRepo() returns [string, string]|error {
    string? githubRepo = os:getEnv("GITHUB_REPOSITORY");
    if githubRepo is string {
        string[] parts = regexp:split(re `/`, githubRepo);
        if parts.length() == 2 {
            return [parts[0], parts[1]];
        }
    }
    return error("Could not determine repository from GITHUB_REPOSITORY env var");
}

// Helper: Extract API version from spec or fallback to tag name
function getApiVersion(string specContent, string tagName) returns string {
    string|error apiVersionResult = extractApiVersion(specContent);
    if apiVersionResult is error {
        print("Could not extract API version, using tag: " + tagName, "Warn", 1);
        return tagName.startsWith("v") ? tagName.substring(1) : tagName;
    }
    return apiVersionResult;
}

// Helper: Save spec and create metadata
function saveSpecAndMetadata(string specContent, string localPath, Repository repo, string apiVersion, string versionDir) returns error? {
    error? saveResult = saveSpec(specContent, localPath);
    if saveResult is error {
        print("Save failed: " + saveResult.message(), "Error", 1);
        return saveResult;
    }

    error? metadataResult = createMetadataFile(repo, apiVersion, versionDir);
    if metadataResult is error {
        print("Metadata creation failed: " + metadataResult.message(), "Error", 1);
    }
    return;
}

// Helper: Build update result record
function buildUpdateResult(Repository repo, string oldVersion, string newVersion, string apiVersion,
        string downloadUrl, string localPath, boolean contentChanged, string updateType) returns UpdateResult {
    return {
        repo: repo,
        oldVersion: oldVersion,
        newVersion: newVersion,
        apiVersion: apiVersion,
        downloadUrl: downloadUrl,
        localPath: localPath,
        contentChanged: contentChanged,
        updateType: updateType
    };
}

// Helper: Handle release fetch error
function handleReleaseFetchError(error err, string owner, string repo) returns error {
    string errorMsg = err.message();
    if errorMsg.includes("404") {
        print(string `No releases found for ${owner}/${repo}`, "Error", 1);
    } else if errorMsg.includes("401") || errorMsg.includes("403") {
        print("Authentication failed", "Error", 1);
    } else {
        print(string `Error: ${errorMsg}`, "Error", 1);
    }
    return err;
}

// Helper: Process a valid release and check for updates
function processRelease(github:Client githubClient, Repository repo, github:Release release) returns UpdateResult|error? {
    string tagName = release.tag_name;
    string? publishedAt = release.published_at;

    if release.prerelease || release.draft {
        print(string `Skipping pre-release: ${tagName}`, "Info", 1);
        return ();
    }

    print(string `Latest release tag: ${tagName}`, "Info", 1);
    if publishedAt is string {
        print(string `Published: ${publishedAt}`, "Info", 1);
    }

    string|error specContent = downloadSpec(githubClient, repo.owner, repo.repo, repo.releaseAssetName, tagName, repo.specPath);
    if specContent is error {
        print("Download failed: " + specContent.message(), "Error", 1);
        return error(specContent.message());
    }

    boolean versionChanged = hasVersionChanged(repo.lastVersion, tagName);
    string contentHash = calculateHash(specContent);
    boolean contentChanged = hasContentChanged(repo.lastContentHash, contentHash);

    print(string `Content Hash: ${contentHash.substring(0, 16)}...`, "Info", 1);

    if !versionChanged && !contentChanged {
        print(string `No updates (version: ${repo.lastVersion}, content unchanged)`, "Info", 1);
        return ();
    }

    string updateType = versionChanged && contentChanged ? "both" : (versionChanged ? "version" : "content");
    print(string `UPDATE DETECTED! (Type: ${updateType})`, "Info", 1);

    string apiVersion = getApiVersion(specContent, tagName);
    string versionDir = "../openapi/" + repo.vendor + "/" + repo.api + "/" + apiVersion;

    // Check if spec file already exists - if yes, skip saving
    boolean fileExists = check specFileExists(versionDir);
    if fileExists {
        print(string `Spec file already exists for version ${apiVersion}, skipping save`, "Info", 1);
        return ();
    }

    // Detect file extension from content to preserve original format
    string fileExtension = getFileExtension(specContent);
    string localPath = versionDir + "/openapi." + fileExtension;

    error? saveError = saveSpecAndMetadata(specContent, localPath, repo, apiVersion, versionDir);
    if saveError is error {
        return saveError;
    }

    string oldVersion = repo.lastVersion;
    repo.lastVersion = tagName;
    repo.lastContentHash = contentHash;

    return buildUpdateResult(
        repo, oldVersion, tagName, apiVersion,
        "https://github.com/" + repo.owner + "/" + repo.repo + "/releases/tag/" + tagName,
        localPath, contentChanged, updateType
    );
}

// Process repository with release-tag versioning strategy
function processReleaseTagRepo(github:Client githubClient, Repository repo) returns UpdateResult|error? {
    print(string `Checking: ${repo.name} (${repo.vendor}/${repo.api}) [Release-Tag Strategy]`, "Info", 0);

    github:Release|error latestRelease = githubClient->/repos/[repo.owner]/[repo.repo]/releases/latest();

    if latestRelease is error {
        return handleReleaseFetchError(latestRelease, repo.owner, repo.repo);
    }

    return processRelease(githubClient, repo, latestRelease);
}

// Process repository with file-based versioning strategy
function processFileBasedRepo(Repository repo) returns UpdateResult|error? {
    print(string `Checking: ${repo.name} (${repo.vendor}/${repo.api}) [File-Based Strategy]`, "Info", 0);

    string branch = repo.branch is string ? <string>repo.branch : "master";
    print(string `Branch: ${branch}`, "Info", 1);
    print(string `Current tracked version: ${repo.lastVersion}`, "Info", 1);

    string|error specContent = downloadSpecFromBranch(
            repo.owner,
            repo.repo,
            branch,
            repo.specPath
    );

    if specContent is error {
        print("Download failed: " + specContent.message(), "Error", 1);
        return error(specContent.message());
    }

    string contentHash = calculateHash(specContent);
    boolean contentChanged = hasContentChanged(repo.lastContentHash, contentHash);

    print(string `Content Hash: ${contentHash.substring(0, 16)}...`, "Info", 1);

    string|error apiVersionResult = extractApiVersion(specContent);

    if apiVersionResult is error {
        print("Could not extract API version from spec content", "Error", 1);
        print("Skipping this repository - please check the spec format", "Warn", 1);
        return error("Cannot extract version from spec");
    }

    string apiVersion = apiVersionResult;
    print(string `Current API Version in spec: ${apiVersion}`, "Info", 1);

    boolean versionChanged = hasVersionChanged(repo.lastVersion, apiVersion);

    if versionChanged || contentChanged {
        string updateType = versionChanged && contentChanged ? "both" : (versionChanged ? "version" : "content");
        print(string `UPDATE DETECTED! (${repo.lastVersion} -> ${apiVersion}, Type: ${updateType})`, "Info", 1);

        string versionDir = "../openapi/" + repo.vendor + "/" + repo.api + "/" + apiVersion;

        // Check if spec file already exists - if yes, skip saving
        boolean fileExists = check specFileExists(versionDir);
        if fileExists {
            print(string `Spec file already exists for version ${apiVersion}, skipping save`, "Info", 1);
            return ();
        }

        // Detect file extension from content to preserve original format
        string fileExtension = getFileExtension(specContent);
        string localPath = versionDir + "/openapi." + fileExtension;

        if !versionChanged && contentChanged {
            print(string `Content update in same version ${apiVersion} - replacing existing files`, "Info", 1);
        }

        error? saveResult = saveSpec(specContent, localPath);
        if saveResult is error {
            print("Save failed: " + saveResult.message(), "Error", 1);
            return error(saveResult.message());
        }

        error? metadataResult = createMetadataFile(repo, apiVersion, versionDir);
        if metadataResult is error {
            print("Metadata creation failed: " + metadataResult.message(), "Error", 1);
        }

        string oldVersion = repo.lastVersion;
        repo.lastVersion = apiVersion;
        repo.lastContentHash = contentHash;

        return {
            repo: repo,
            oldVersion: oldVersion,
            newVersion: apiVersion,
            apiVersion: apiVersion,
            downloadUrl: string `https://github.com/${repo.owner}/${repo.repo}/blob/${branch}/${repo.specPath}`,
            localPath: localPath,
            contentChanged: contentChanged,
            updateType: updateType
        };
    } else {
        print(string `No updates (version: ${apiVersion}, content unchanged)`, "Info", 1);
        return ();
    }
}

// Process repository with rollout-based versioning strategy
function processRolloutBasedRepo(github:Client githubClient, Repository repo, string token) returns UpdateResult|error? {
    print(string `Checking: ${repo.name} (${repo.vendor}/${repo.api}) [Rollout-Based Strategy]`, "Info", 0);

    string branch = repo.branch is string ? <string>repo.branch : "main";
    print(string `Branch: ${branch}`, "Info", 1);
    print(string `Current tracked rollout: ${repo.lastVersion}`, "Info", 1);

    string[] pathParts = regexp:split(re `/Rollouts/`, repo.specPath);
    if pathParts.length() < 2 {
        print("Invalid path format - cannot find Rollouts directory", "Error", 1);
        return error("Invalid rollout path format");
    }

    string basePath = pathParts[0] + "/Rollouts";

    string|error latestRollout = findLatestRollout(repo.owner, repo.repo, branch, basePath, token);

    if latestRollout is error {
        print("Failed to find rollouts: " + latestRollout.message(), "Error", 1);
        return error(latestRollout.message());
    }

    print(string `Latest rollout: ${latestRollout}`, "Info", 1);

    boolean rolloutChanged = hasVersionChanged(repo.lastVersion, latestRollout);

    string[] afterRollouts = regexp:split(re `/Rollouts/[0-9]+/`, repo.specPath);
    string afterRolloutPath = afterRollouts.length() > 1 ? afterRollouts[1] : "";
    string currentSpecPath = rolloutChanged ?
        basePath + "/" + latestRollout + "/" + afterRolloutPath :
        repo.specPath;

    string|error specContent = downloadSpecFromBranch(
            repo.owner,
            repo.repo,
            branch,
            currentSpecPath
    );

    if specContent is error {
        print("Download failed: " + specContent.message(), "Error", 1);
        return error(specContent.message());
    }

    string contentHash = calculateHash(specContent);
    boolean contentChanged = hasContentChanged(repo.lastContentHash, contentHash);

    print(string `Content Hash: ${contentHash.substring(0, 16)}...`, "Info", 1);

    if rolloutChanged || contentChanged {
        string updateType = rolloutChanged && contentChanged ? "both" : (rolloutChanged ? "rollout" : "content");
        print(string `UPDATE DETECTED! (Rollout ${repo.lastVersion} -> ${latestRollout}, Type: ${updateType})`, "Info", 1);

        string apiVersion = "";
        var apiVersionResult = extractApiVersion(specContent);
        if apiVersionResult is error {
            print("Could not extract API version from spec, using rollout number", "Warn", 1);
            apiVersion = latestRollout;
        } else {
            apiVersion = apiVersionResult;
        }

        string versionDir = "../openapi/" + repo.vendor + "/" + repo.api + "/rollout-" + latestRollout;

        // Check if spec file already exists - if yes, skip saving
        boolean fileExists = check specFileExists(versionDir);
        if fileExists {
            print(string `Spec file already exists for rollout ${latestRollout}, skipping save`, "Info", 1);
            return ();
        }

        // Detect file extension from content to preserve original format
        string fileExtension = getFileExtension(specContent);
        string localPath = versionDir + "/openapi." + fileExtension;

        if !rolloutChanged && contentChanged {
            print(string `Content update within rollout ${latestRollout} - replacing existing files`, "Info", 1);
        }

        error? saveResult = saveSpec(specContent, localPath);
        if saveResult is error {
            print("Save failed: " + saveResult.message(), "Error", 1);
            return error(saveResult.message());
        }

        error? metadataResult = createMetadataFile(repo, latestRollout, versionDir);
        if metadataResult is error {
            print("Metadata creation failed: " + metadataResult.message(), "Error", 1);
        }

        string oldVersion = repo.lastVersion;
        repo.lastVersion = latestRollout;
        repo.specPath = currentSpecPath;
        repo.lastContentHash = contentHash;

        return {
            repo: repo,
            oldVersion: "rollout-" + oldVersion,
            newVersion: "rollout-" + latestRollout,
            apiVersion: "rollout-" + latestRollout,
            downloadUrl: string `https://github.com/${repo.owner}/${repo.repo}/blob/${branch}/${currentSpecPath}`,
            localPath: localPath,
            contentChanged: contentChanged,
            updateType: updateType
        };
    } else {
        print(string `No updates (rollout: ${latestRollout}, content unchanged)`, "Info", 1);
        return ();
    }
}

// Main monitoring function
public function main() returns error? {
    print("=== Dependabot OpenAPI Monitor ===", "Info", 0);
    print("Starting OpenAPI specification monitoring...", "Info", 0);

    string? ghToken = os:getEnv("GH_TOKEN");
    string? ballerinaToken = os:getEnv("BALLERINA_BOT_TOKEN");
    string? githubToken = os:getEnv("GITHUB_TOKEN");

    string token = "";
    if ghToken is string && ghToken.length() > 0 {
        token = ghToken;
    } else if ballerinaToken is string && ballerinaToken.length() > 0 {
        token = ballerinaToken;
    } else if githubToken is string && githubToken.length() > 0 {
        token = githubToken;
    }

    if token.length() == 0 {
        print("GitHub token not found. Please set one of: GH_TOKEN, BALLERINA_BOT_TOKEN, or GITHUB_TOKEN", "Error", 0);
        return;
    }

    github:Client githubClient = check new ({
        auth: {
            token: token
        }
    });

    json reposJson = check io:fileReadJson("../repos.json");
    Repository[] repos = check reposJson.cloneWithType();

    print(string `Found ${repos.length()} repositories to monitor.`, "Info", 0);
    io:println("");

    UpdateResult[] updates = [];

    foreach Repository repo in repos {
        UpdateResult|error? result = ();

        if repo.versioningStrategy == RELEASE_TAG {
            result = processReleaseTagRepo(githubClient, repo);
        } else if repo.versioningStrategy == FILE_BASED {
            result = processFileBasedRepo(repo);
        } else if repo.versioningStrategy == ROLLOUT_BASED {
            result = processRolloutBasedRepo(githubClient, repo, token);
        } else {
            print(string `Unknown versioning strategy: ${repo.versioningStrategy}`, "Warn", 0);
        }

        if result is UpdateResult {
            updates.push(result);
        }

        io:println("");
    }

    if updates.length() > 0 {
        io:println("");
        print(string `Found ${updates.length()} updates:`, "Info", 0);
        io:println("");

        string[] updateSummary = [];
        foreach UpdateResult update in updates {
            string summary = string `${update.repo.vendor}/${update.repo.api}: ${update.oldVersion} -> ${update.newVersion} (${update.updateType} update)`;
            print(summary, "Info", 1);
            updateSummary.push(summary);
        }

        check io:fileWriteJson("../repos.json", repos.toJson());
        io:println("");
        print("Updated repos.json with new versions and content hashes", "Info", 0);

        string summaryContent = string:'join("\n", ...updateSummary);
        check io:fileWriteString("../UPDATE_SUMMARY.txt", summaryContent);

        print("Done! Updates are ready for review.", "Info", 0);
    } else {
        print("All specifications are up-to-date!", "Info", 0);
    }
}
