package com.skylab.account;

import jakarta.ws.rs.core.MultivaluedHashMap;
import jakarta.ws.rs.core.MultivaluedMap;
import jakarta.ws.rs.core.PathSegment;
import jakarta.ws.rs.core.UriBuilder;
import jakarta.ws.rs.core.UriInfo;

import java.net.URI;
import java.util.List;

/** Immutable issuer-only URI snapshot for a committed background notice; no request/token/query data. */
record DetachedBaseUri(URI getBaseUri) implements UriInfo {
    @Override public URI getRequestUri() { return getBaseUri; }
    @Override public URI getAbsolutePath() { return getBaseUri; }
    @Override public UriBuilder getBaseUriBuilder() { return UriBuilder.fromUri(getBaseUri); }
    @Override public UriBuilder getRequestUriBuilder() { return getBaseUriBuilder(); }
    @Override public UriBuilder getAbsolutePathBuilder() { return getBaseUriBuilder(); }
    @Override public String getPath() { return ""; }
    @Override public String getPath(boolean decode) { return ""; }
    @Override public List<PathSegment> getPathSegments() { return List.of(); }
    @Override public List<PathSegment> getPathSegments(boolean decode) { return List.of(); }
    @Override public MultivaluedMap<String, String> getPathParameters() { return new MultivaluedHashMap<>(); }
    @Override public MultivaluedMap<String, String> getPathParameters(boolean decode) { return getPathParameters(); }
    @Override public MultivaluedMap<String, String> getQueryParameters() { return new MultivaluedHashMap<>(); }
    @Override public MultivaluedMap<String, String> getQueryParameters(boolean decode) { return getQueryParameters(); }
    @Override public List<String> getMatchedURIs() { return List.of(); }
    @Override public List<String> getMatchedURIs(boolean decode) { return List.of(); }
    @Override public List<Object> getMatchedResources() { return List.of(); }
    @Override public URI resolve(URI uri) { return getBaseUri.resolve(uri); }
    @Override public URI relativize(URI uri) { return getBaseUri.relativize(uri); }
}
