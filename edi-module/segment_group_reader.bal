import ballerina/log;
import ballerina/regex;

type SegmentGroupContext record {|
    int schemaIndex = 0;
    EDISegmentGroup segmentGroup = {};
    EDIUnitSchema[] unitSchemas;
|};

class SegmentGroupReader {

    SegmentReader segmentReader = new ();

    function read(EDIUnitSchema[] currentUnitSchema, EDIContext context, boolean rootGroup) returns EDISegmentGroup|error {
        SegmentGroupContext sgContext = {unitSchemas: currentUnitSchema};
        EDISchema ediSchema = context.schema;
        while context.rawIndex < context.rawSegments.length() {
            string sDesc = context.rawSegments[context.rawIndex];
            string segmentDesc = regex:replaceAll(sDesc, "\n", "");
            string[] fields = split(segmentDesc, ediSchema.delimiters.'field);
            if ediSchema.ignoreSegments.indexOf(fields[0], 0) != () {
                context.rawIndex += 1;
                continue;
            }

            boolean segmentMapped = false;
            while sgContext.schemaIndex < sgContext.unitSchemas.length() {
                EDIUnitSchema? segSchema = currentUnitSchema[sgContext.schemaIndex];
                if (segSchema is EDISegSchema) {
                    log:printDebug(string `Trying to match with segment mapping ${printSegMap(segSchema)}`);
                    if segSchema.code != fields[0] {
                        check self.ignoreSchema(segSchema, sgContext, context);
                        continue;
                    }
                    EDISegment ediRecord = check self.segmentReader.read(segSchema, fields, ediSchema, segmentDesc);
                    check self.placeEDISegment(ediRecord, segSchema, sgContext, context);
                    context.rawIndex += 1;
                    segmentMapped = true;
                    break;

                } else if segSchema is EDISegGroupSchema {
                    log:printDebug(string `Trying to match with segment group mapping ${printSegGroupMap(segSchema)}`);
                    EDIUnitSchema firstSegSchema = segSchema.segments[0];
                    if firstSegSchema is EDISegGroupSchema {
                        return error("First item of segment group must be a segment. Found a segment group.\nSegment group: " + printSegGroupMap(segSchema));
                    }
                    if firstSegSchema.code != fields[0] {
                        check self.ignoreSchema(segSchema, sgContext, context);
                        continue;
                    }
                    EDISegmentGroup segmentGroup = check self.read(segSchema.segments, context, false);
                    if segmentGroup.length() > 0 {
                        check self.placeEDISegmentGroup(segmentGroup, segSchema, sgContext, context);
                    }
                    segmentMapped = true;
                    break;
                }
            }
            if !segmentMapped && rootGroup {
                return error(string `Segment text: ${context.rawSegments[context.rawIndex]} is not matched with the mapping.
                Curren row: ${context.rawIndex}`);
            }

            if sgContext.schemaIndex >= sgContext.unitSchemas.length() {
                // We have completed mapping with this segment group.
                break;
            }
        }
        check self.validateRemainingSchemas(sgContext);
        return sgContext.segmentGroup;
    }

    # Ignores the given segment of segment group schema if any of the below two conditions are satisfied. 
    # This function will be called if a schema cannot be mapped with the next available segment text.
    #
    # 1. Given schema is optional
    # 2. Given schema is a repeatable one and it has already occured at least once
    #
    # If above conditions are not met, schema cannot be ignored, and should result in an error. 
    #
    # + segSchema - Segment schema or segment group schema to be ignored
    # + sgContext - Segment group parsing context  
    # + context - EDI parsing context
    # + return - Return error if the given mapping cannot be ignored.
    function ignoreSchema(EDIUnitSchema segSchema, SegmentGroupContext sgContext, EDIContext context) returns error? {

        // If the current segment mapping is optional, we can ignore the current mapping and compare the 
        // current segment with the next mapping.
        if segSchema.minOccurances == 0 {
            log:printDebug(string `Ignoring optional segment: ${printEDIUnitMapping(segSchema)} | Segment text: ${context.rawIndex < context.rawSegments.length() ? context.rawSegments[context.rawIndex] : "-- EOF --"}`);
            sgContext.schemaIndex += 1;
            return;
        }

        // If the current segment mapping represents a repeatable segment, and we have already encountered 
        // at least one such segment, we can ignore the current mapping and compare the current segment with 
        // the next mapping.
        if segSchema.maxOccurances != 1 {
            var segments = sgContext.segmentGroup[segSchema.tag];
            if (segments is EDISegment[]|EDISegmentGroup[]) {
                if segments.length() > 0 {
                    // This repeatable segment has already occured at least once. So move to the next mapping.
                    sgContext.schemaIndex += 1;
                    log:printDebug(string `Completed reading repeatable segment: ${printEDIUnitMapping(segSchema)} | Segment text: ${context.rawIndex < context.rawSegments.length() ? context.rawSegments[context.rawIndex] : "-- EOF --"}`);
                    return;
                }
            }
        }

        return error(string `Mandatory unit ${printEDIUnitMapping(segSchema)} missing in the EDI.
        Current segment text: ${context.rawSegments[context.rawIndex]}
        Current mapping index: ${sgContext.schemaIndex}`);
    }

    function placeEDISegment(EDISegment segment, EDISegSchema segSchema, SegmentGroupContext sgContext, EDIContext context) returns error? {
        if (segSchema.maxOccurances == 1) {
            // Current segment has matched with the current mapping AND current segment is not repeatable.
            // So we can move to the next mapping.
            log:printDebug(string `Completed reading non-repeatable segment: ${printSegMap(segSchema)}.
            Segment text: ${context.rawSegments[context.rawIndex]}`);
            sgContext.schemaIndex += 1;
            sgContext.segmentGroup[segSchema.tag] = segment;
        } else {
            // Current mapping points to a repeatable segment. So we are using a EDISegment[] array to hold segments.
            // Also we can't increment the mapping index here as next segment can also match with the current mapping
            // as the segment is repeatable.
            var segments = sgContext.segmentGroup[segSchema.tag];
            if (segments is EDISegment[]) {
                if (segSchema.maxOccurances != -1 && segments.length() >= segSchema.maxOccurances) {
                    return error(string `${segSchema.code} is repeatable segment with maximum limit of ${segSchema.maxOccurances}.
                    EDI document contains more such segments than the allowed limit. Current row: ${context.rawIndex}`);
                }
                segments.push(segment);
            } else if segments is () {
                segments = [segment];
                sgContext.segmentGroup[segSchema.tag] = segments;
            } else {
                return error(string `${segSchema.code} must be a segment array.`);
            }
        }
    }

    function placeEDISegmentGroup(EDISegmentGroup segmentGroup, EDISegGroupSchema segGroupSchema, SegmentGroupContext sgContext, EDIContext context) returns error? {
        if segGroupSchema.maxOccurances == 1 {
            // This is a non-repeatable mapping. So we have to compare the next segment with the next mapping.
            log:printDebug(string `Completed reading non-repeating segment group ${printSegGroupMap(segGroupSchema)} | Current segment text: ${context.rawIndex < context.rawSegments.length() ? context.rawSegments[context.rawIndex] : "-- EOF --"}`);
            sgContext.schemaIndex += 1;
            sgContext.segmentGroup[segGroupSchema.tag] = segmentGroup;
        } else {
            // This is a repeatable mapping. So we compare the next segment also with the current mapping.
            // i.e. we don't increment the mapping index.
            var segmentGroups = sgContext.segmentGroup[segGroupSchema.tag];
            if segmentGroups is EDISegmentGroup[] {
                if segGroupSchema.maxOccurances != -1 && segmentGroups.length() >= segGroupSchema.maxOccurances {
                    return error(string `${printSegGroupMap(segGroupSchema)} is repeatable segment group with maximum limit of ${segGroupSchema.maxOccurances}.
                    EDI document contains more such segment groups than the allowed limit. Current row: ${context.rawIndex}`);
                }
                segmentGroups.push(segmentGroup);
            } else if segmentGroups is () {
                segmentGroups = [segmentGroup];
                sgContext.segmentGroup[segGroupSchema.tag] = segmentGroups;
            } else {
                return error(string `${segGroupSchema.tag} must be a segment group array.`);
            }

        }
    }

    function validateRemainingSchemas(SegmentGroupContext sgContext) returns error? {
        if sgContext.schemaIndex < sgContext.unitSchemas.length() - 1 {
            int i = sgContext.schemaIndex + 1;
            while i < sgContext.unitSchemas.length() {
                EDIUnitSchema umap = sgContext.unitSchemas[i];
                int minOccurs = 1;
                if umap is EDISegSchema {
                    minOccurs = umap.minOccurances;
                } else {
                    minOccurs = umap.minOccurances;
                }
                if minOccurs > 0 {
                    return error(string `Mandatory segment ${printEDIUnitMapping(umap)} is not found.`);
                }
                i += 1;
            }
        }
    }
}
