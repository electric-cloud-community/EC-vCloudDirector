@files = (

    #Configuration Files
    ['//procedure[procedureName="CreateConfiguration"]/propertySheet/property[propertyName="ec_parameterForm"]/value',  'vCloudDirectorCreateConfigForm.xml'],
    ['//property[propertyName="ui_forms"]/propertySheet/property[propertyName="vCloudDirectorCreateConfigForm"]/value', 'vCloudDirectorCreateConfigForm.xml'],
    ['//property[propertyName="ui_forms"]/propertySheet/property[propertyName="vCloudDirectorEditConfigForm"]/value',   'vCloudDirectorEditConfigForm.xml'],

    ['//procedure[procedureName="CreateConfiguration"]/step[stepName="CreateConfiguration"]/command',       'conf/createcfg.pl'],
    ['//procedure[procedureName="CreateConfiguration"]/step[stepName="CreateAndAttachCredential"]/command', 'conf/createAndAttachCredential.pl'],
    ['//procedure[procedureName="CreateConfiguration"]/step[stepName="AttemptConnection"]/command',         'conf/attemptConnection.pl'],
    ['//procedure[procedureName="DeleteConfiguration"]/step[stepName="DeleteConfiguration"]/command',       'conf/deletecfg.pl'],

    #Procedures Files
    ['//procedure[procedureName="Provision"]/propertySheet/property[propertyName="ec_parameterForm"]/value',          'ui_forms/Provision-Form.xml'],
    ['//step[stepName="Provision"]/command',                                                                          'vapp/provision.pl'],
    ['//procedure[procedureName="Capture"]/propertySheet/property[propertyName="ec_parameterForm"]/value',            'ui_forms/Capture-Form.xml'],
    ['//step[stepName="Capture"]/command',                                                                            'vapp/capture.pl'],
    ['//procedure[procedureName="Cleanup"]/propertySheet/property[propertyName="ec_parameterForm"]/value',            'ui_forms/Cleanup-Form.xml'],
    ['//step[stepName="Cleanup"]/command',                                                                            'vapp/cleanup.pl'],
    ['//procedure[procedureName="Clone"]/propertySheet/property[propertyName="ec_parameterForm"]/value',              'ui_forms/Clone-Form.xml'],
    ['//step[stepName="Clone"]/command',                                                                              'vapp/clone.pl'],
    ['//procedure[procedureName="GetvApp"]/propertySheet/property[propertyName="ec_parameterForm"]/value',            'ui_forms/GetvApp-Form.xml'],
    ['//step[stepName="GetvApp"]/command',                                                                            'vapp/getvApp.pl'],
    ['//procedure[procedureName="Start vApp"]/propertySheet/property[propertyName="ec_parameterForm"]/value',         'ui_forms/StartvApp-Form.xml'],
    ['//step[stepName="Start vApp"]/command',                                                                         'vapp/startvApp.pl'],
    ['//procedure[procedureName="CloudManagerGrow"]/propertySheet/property[propertyName="ec_parameterForm"]/value',   'ui_forms/Grow-Form.xml'],
    ['//step[stepName="grow"]/command',                                                                               'vapp/step.grow.pl'],
    ['//procedure[procedureName="CloudManagerShrink"]/propertySheet/property[propertyName="ec_parameterForm"]/value', 'ui_forms/Shrink-Form.xml'],
    ['//step[stepName="shrink"]/command',                                                                             'vapp/step.shrink.pl'],
    ['//procedure[procedureName="CloudManagerSync"]/propertySheet/property[propertyName="ec_parameterForm"]/value',   'ui_forms/Sync-Form.xml'],
    ['//step[stepName="sync"]/command',                                                                               'vapp/step.sync.pl'],

    #Main Files
    ['//property[propertyName="postp_matchers"]/value', 'postp_matchers.pl'],
    ['//property[propertyName="ec_setup"]/value',       'ec_setup.pl'],
    ['//property[propertyName="preamble"]/value',       'preamble.pl'],
    ['//property[propertyName="vCloudDirector"]/value', 'vCloudDirector.pm'],

);

